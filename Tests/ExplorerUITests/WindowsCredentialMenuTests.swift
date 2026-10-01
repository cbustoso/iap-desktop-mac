// CBU-54: "Generate Windows credentials…" (menú por instancia Windows) y
// coordinador reutilizar/generar/regenerar con un vault en memoria.
import AppKit
import Testing
@testable import ExplorerUI

private let linuxVM = InstanceInfo(project: "p", zone: "z", name: "web-01", os: .linux, status: .running)
private let windowsVM = InstanceInfo(project: "p", zone: "z", name: "adsrv", os: .windows, status: .running)

/// `@unchecked`: estado bajo `lock`.
private final class MemoryVault: WindowsCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: WindowsLogonCredential] = [:]
    var failSaves = false
    var failLoads = false

    func load(for instance: InstanceInfo) throws -> WindowsLogonCredential? {
        struct ReadFailed: Error {}
        return try lock.withLock {
            if failLoads { throw ReadFailed() }
            return stored[instance.id]
        }
    }

    func save(_ credential: WindowsLogonCredential, for instance: InstanceInfo) throws {
        struct WriteFailed: Error {}
        try lock.withLock {
            if failSaves { throw WriteFailed() }
            stored[instance.id] = credential
        }
    }
}

@Suite("Credenciales Windows: menú (CBU-54)")
@MainActor
struct WindowsCredentialMenuTests {
    @Test func onlyWindowsInstancesOfferGenerate() {
        #expect(ExplorerContextMenu.entries(for: .instance(windowsVM)).contains(.command(.generateWindowsCredentials)))
        #expect(!ExplorerContextMenu.entries(for: .instance(linuxVM)).contains(.command(.generateWindowsCredentials)))
        #expect(!ExplorerContextMenu.entries(for: .project(ProjectInfo(name: "p")))
            .contains(.command(.generateWindowsCredentials)))
        #expect(ExplorerCommand.generateWindowsCredentials.title == "Generate Windows credentials…")
    }

    @Test func itemEnabledOnlyWhenAppWiresIt() {
        func item(_ available: Bool) -> NSMenuItem? {
            ExplorerWindowController.contextMenuItems(
                for: .instance(windowsVM), target: nil, windowsCredentialsAvailable: available)
                .first { $0.title == ExplorerCommand.generateWindowsCredentials.title }
        }
        #expect(item(true)?.isEnabled == true)
        #expect(item(true)?.badge == nil)
        #expect(item(false)?.isEnabled == false)
    }

    @Test func menuInvokesCredentialFlowWithInstance() throws {
        let controller = ExplorerWindowController(viewModel: ExplorerViewModel(projects: []))
        controller.window?.isReleasedWhenClosed = false
        var requested: [InstanceInfo] = []
        var connected: [InstanceInfo] = []
        controller.onGenerateWindowsCredentialsRequest = { requested.append($0) }
        controller.onConnectRequest = { connected.append($0) }

        let item = try #require(ExplorerWindowController.contextMenuItems(
            for: .instance(windowsVM), target: controller, windowsCredentialsAvailable: true)
            .first { $0.title == ExplorerCommand.generateWindowsCredentials.title })
        let action = try #require(item.action)
        _ = (item.target as? NSObject)?.perform(action, with: item)

        #expect(requested == [windowsVM])
        #expect(connected.isEmpty)  // genera sin conectar
        controller.close()
    }
}

@Suite("Credenciales Windows: coordinador (CBU-54)")
@MainActor
struct WindowsCredentialCoordinatorTests {
    @Test func reusesStoredCredentialWithoutGenerating() async throws {
        let vault = MemoryVault()
        try vault.save(WindowsLogonCredential(username: "ada", password: "old"), for: windowsVM)
        var calls = 0
        let coordinator = WindowsCredentialCoordinator(vault: vault) { _, user in
            calls += 1
            return WindowsLogonCredential(username: user, password: "new")
        }
        #expect(coordinator.stored(for: windowsVM) == WindowsLogonCredential(username: "ada", password: "old"))
        #expect(calls == 0)
    }

    @Test func generateStoresAndRegenerateReplaces() async throws {
        let vault = MemoryVault()
        var passwords = ["first", "second"]
        var requests: [(InstanceInfo, String)] = []
        let coordinator = WindowsCredentialCoordinator(vault: vault) { instance, user in
            requests.append((instance, user))
            return WindowsLogonCredential(username: user, password: passwords.removeFirst())
        }
        #expect(coordinator.stored(for: windowsVM) == nil)

        let first = try await coordinator.generate(for: windowsVM, username: "ada")
        #expect(first.persisted)
        #expect(coordinator.stored(for: windowsVM)?.password == "first")

        let second = try await coordinator.generate(for: windowsVM, username: "ada")
        #expect(second.credential.password == "second")
        #expect(try vault.load(for: windowsVM) == WindowsLogonCredential(username: "ada", password: "second"))
        #expect(requests.map(\.1) == ["ada", "ada"])
        #expect(requests.allSatisfy { $0.0 == windowsVM })
    }

    @Test func failedGenerationKeepsPreviousCredential() async throws {
        struct ResetFailed: Error {}
        let vault = MemoryVault()
        try vault.save(WindowsLogonCredential(username: "ada", password: "old"), for: windowsVM)
        let coordinator = WindowsCredentialCoordinator(vault: vault) { _, _ in throw ResetFailed() }
        await #expect(throws: ResetFailed.self) { try await coordinator.generate(for: windowsVM, username: "ada") }
        #expect(coordinator.stored(for: windowsVM)?.password == "old")
    }

    @Test func unsavableCredentialIsStillDeliveredButFlagged() async throws {
        let vault = MemoryVault()
        vault.failSaves = true
        let coordinator = WindowsCredentialCoordinator(vault: vault) { _, user in
            WindowsLogonCredential(username: user, password: "pw")
        }
        let generated = try await coordinator.generate(for: windowsVM, username: "ada")
        #expect(generated.credential.password == "pw")
        #expect(!generated.persisted)
    }

    @Test func unusableOrUnreadableStoredIsIgnored() throws {
        let vault = MemoryVault()
        try vault.save(WindowsLogonCredential(username: "", password: "pw"), for: windowsVM)
        let coordinator = WindowsCredentialCoordinator(vault: vault) { _, _ in fatalError("no se usa") }
        #expect(coordinator.stored(for: windowsVM) == nil)
        try vault.save(WindowsLogonCredential(username: "ada", password: ""), for: windowsVM)
        #expect(coordinator.stored(for: windowsVM) == nil)
        try vault.save(WindowsLogonCredential(username: "ada", password: "pw"), for: windowsVM)
        vault.failLoads = true
        #expect(coordinator.stored(for: windowsVM) == nil)
    }

    @Test func credentialNeverPrintsPassword() {
        let credential = WindowsLogonCredential(username: "ada", password: "S3cr3t!pw")
        var dumped = ""
        dump(credential, to: &dumped)
        for text in [String(describing: credential), String(reflecting: credential), "\(credential)", dumped] {
            #expect(!text.contains("S3cr3t"))
            #expect(text.contains("<redacted>"))
        }
    }
}
