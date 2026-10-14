// GH-66: UI tests críticos de extremo a extremo (headless, sin red/procesos
// reales), siguiendo el patrón de `SnapshotSmokeTests` (CBU-32: nada de
// mocks a medias, se ejercitan los mismos puntos de entrada públicos que usa
// `Sources/App`) pero sin lanzar el binario — todo in-process sobre
// `ExplorerWindowController`/`SessionAreaView`/`SftpBrowserView`/
// `WindowsCredentialCoordinator`, los únicos tipos de `ExplorerUI` (único
// dependency de este target, ver Package.swift) que intervienen en cada
// flujo. Cuatro flujos, cada uno con su "launcher"/API mockeada en memoria:
//
//  1. Login: un "session launcher" stubbed (closure async que sustituye al
//     `AuthKit.LoginSession.Launcher` real: sin abrir navegador ni red)
//     entrega un email que `ExplorerWindowController.showAccount` refleja.
//  2. SSH: abrir una pestaña de sesión mock (NSView sin backend real) vía
//     `sessionTabs`/`onConnectRequest`, y cerrarla con el botón `×`
//     (`onCloseRequested`, GH-64) + `closeSession`.
//  3. SFTP: pestaña "Files" con un `SftpBrowserModel` falso en memoria
//     (mismo patrón que `SftpBrowserViewTests`), navegación + listado.
//  4. Generate Windows credentials: menú contextual → `onGenerateWindowsCredentialsRequest`
//     → `WindowsCredentialCoordinator` con una API GCE mockeada y un vault en
//     memoria (mismo patrón que `WindowsCredentialMenuTests`).
import AppKit
import Testing
@testable import ExplorerUI

private let linuxVM = InstanceInfo(project: "p", zone: "z", name: "web-01", os: .linux, status: .running)
private let windowsVM = InstanceInfo(project: "p", zone: "z", name: "adsrv", os: .windows, status: .running)

@MainActor
private func makeController() -> ExplorerWindowController {
    let controller = ExplorerWindowController(
        viewModel: ExplorerViewModel(projects: [
            ProjectInfo(name: "p", zones: [
                ZoneInfo(project: "p", name: "z", instances: [linuxVM, windowsVM]),
            ]),
        ]))
    controller.window?.isReleasedWhenClosed = false
    return controller
}

// MARK: - 1. Login con session launcher stubbed

@Suite("Flujo crítico: login (GH-66)")
@MainActor
struct CriticalLoginFlowTests {
    /// Equivalente headless de `AuthKit.LoginSession.Launcher`
    /// (`@Sendable (URL, String?) async throws -> URL`): aquí no hay URL ni
    /// callback real, solo el resultado que la App obtendría tras el OAuth y
    /// pasaría a `showAccount`. Stub puro: no abre navegador, no hace red.
    private struct StubbedSessionLauncher {
        var result: Result<String, Error>
        private(set) var invocations = 0

        mutating func signIn() async throws -> String {
            invocations += 1
            return try result.get()
        }
    }

    private struct LauncherFailure: Error {}

    @Test func signInUpdatesAccountFromStubbedLauncher() async throws {
        let controller = makeController()
        #expect(controller.accountText == "Sin sesión")

        var launcher = StubbedSessionLauncher(result: .success("ada@example.com"))
        let email = try await launcher.signIn()
        controller.showAccount(email: email)

        #expect(launcher.invocations == 1)
        #expect(controller.accountText == "ada@example.com")
        #expect(controller.statusBar.accountLabel.toolTip == "ada@example.com")
    }

    @Test func failedLoginLeavesAccountSignedOut() async throws {
        let controller = makeController()
        var launcher = StubbedSessionLauncher(result: .failure(LauncherFailure()))

        await #expect(throws: LauncherFailure.self) { try await launcher.signIn() }
        // La App no llama a showAccount si el launcher falla: sigue "Sin sesión".
        #expect(controller.accountText == "Sin sesión")
    }

    @Test func signOutClearsTheAccountAgain() async throws {
        let controller = makeController()
        var launcher = StubbedSessionLauncher(result: .success("ada@example.com"))
        controller.showAccount(email: try await launcher.signIn())
        #expect(controller.accountText == "ada@example.com")

        controller.showAccount(email: nil)  // Sign Out
        #expect(controller.accountText == "Sin sesión")
    }
}

// MARK: - 2. Apertura y cierre (×) de pestaña SSH mock

@Suite("Flujo crítico: pestaña SSH mock (GH-66)")
@MainActor
struct CriticalSshTabFlowTests {
    /// Vista mínima que representa el backend SSH mockeado (sin SSHKit: este
    /// target no depende de él). Lo único que importa a este flujo es que
    /// `openSession`/`closeSession` muevan la pestaña correctamente.
    private final class MockSshSessionView: NSView {
        private(set) var closed = false
        func markClosed() { closed = true }
    }

    @Test func doubleClickConnectOpensASessionTabForLinuxOnly() {
        let controller = makeController()
        var connected: [InstanceInfo] = []
        let sessionView = MockSshSessionView()
        controller.onConnectRequest = { instance in
            connected.append(instance)
            controller.sessionTabs.openSession(identifier: instance.id, title: instance.name, content: sessionView)
        }

        #expect(controller.selectNode(id: ExplorerNode.instance(linuxVM).id))
        controller.connectSelectedInstance(nil)

        #expect(connected == [linuxVM])
        #expect(controller.sessionTabs.sessionIdentifiers == [linuxVM.id])
        #expect(controller.sessionTabs.selectedSessionIdentifier == linuxVM.id)
    }

    @Test func closeButtonRequestClosesExactlyThatTabAndCleansUpTheMockSession() throws {
        let controller = makeController()
        let webSession = MockSshSessionView()
        let dbSession = MockSshSessionView()
        controller.sessionTabs.openSession(identifier: linuxVM.id, title: "web-01", content: webSession)
        controller.sessionTabs.openSession(identifier: "p/z/db-01", title: "db-01", content: dbSession)
        #expect(controller.sessionTabs.sessionIdentifiers == [linuxVM.id, "p/z/db-01"])

        // La App cablea onCloseRequested a: confirmar (si procede) + cerrar backend + quitar pestaña.
        var closedIdentifiers: [String] = []
        controller.sessionTabs.onCloseRequested = { identifier in
            closedIdentifiers.append(identifier)
            if identifier == linuxVM.id { webSession.markClosed() } else { dbSession.markClosed() }
            controller.sessionTabs.closeSession(identifier: identifier)
        }

        let area = controller.sessionArea
        let webTab = try #require(area.tabItems[linuxVM.id])
        webTab.isHovering = true
        webTab.closeButton.performClick(nil)

        #expect(closedIdentifiers == [linuxVM.id])
        #expect(webSession.closed)
        #expect(!dbSession.closed)  // solo se cerró la pestaña pulsada
        #expect(controller.sessionTabs.sessionIdentifiers == ["p/z/db-01"])
    }

    @Test func closingTheLastSessionTabRestoresTheEmptyState() {
        let controller = makeController()
        let area = controller.sessionArea
        area.openSession(identifier: linuxVM.id, title: "web-01", content: MockSshSessionView())
        #expect(!area.isShowingEmptyState)

        controller.sessionTabs.closeSession(identifier: linuxVM.id)
        #expect(area.isShowingEmptyState)
        #expect(controller.sessionTabs.sessionIdentifiers.isEmpty)
    }
}

// MARK: - 3. Browse SFTP mock

@Suite("Flujo crítico: browse SFTP mock (GH-66)")
@MainActor
struct CriticalSftpBrowseFlowTests {
    /// `SftpBrowserModel` falso en memoria (sin SFTPKit, igual que
    /// `SftpBrowserViewTests.FakeBrowserModel`): basta para ejercitar
    /// listado, navegación y cierre de la pestaña "Files".
    private final class MockFileBrowser: SftpBrowserModel {
        var rows: [SftpBrowserRow] = [
            SftpBrowserRow(
                name: "logs", size: "—", modified: "2024-01-01 00:00", permissions: "drwxr-xr-x",
                isDirectory: true, isDownloadable: false),
            SftpBrowserRow(
                name: "app.log", size: "128 B", modified: "2024-01-01 00:05", permissions: "-rw-r--r--",
                isDirectory: false, isDownloadable: true),
        ]
        var crumbs = [SftpBrowserCrumb(title: "/", path: "/"), SftpBrowserCrumb(title: "home", path: "/home")]
        var transfers: [SftpBrowserTransferRow] = []
        var isLoading = false
        var errorText: String?
        var onChange: (@MainActor () -> Void)?

        private(set) var navigated: [String] = []
        private(set) var opened: [Int] = []
        private(set) var closed = false

        func openRow(_ index: Int) { opened.append(index) }
        func navigate(to path: String) { navigated.append(path) }
        func goUp() {}
        func refresh() {}
        func conflictingNames(for localURLs: [URL]) -> [String] { [] }
        func upload(_ localURLs: [URL]) {}
        func download(row: Int, to fileURL: URL, completion: @escaping @MainActor ((any Error)?) -> Void) {
            completion(nil)
        }
        func close() { closed = true }
    }

    @Test func browseFilesOpensAFilesTabListingTheMockedEntries() {
        let controller = makeController()
        let browser = MockFileBrowser()
        let browserView = SftpBrowserView(model: browser)
        let filesTabID = "\(linuxVM.id)#files"

        controller.sessionTabs.openSession(identifier: filesTabID, title: "\(linuxVM.name) — Files", content: browserView)

        #expect(controller.sessionTabs.sessionIdentifiers.contains(filesTabID))
        #expect(browserView.tableView.numberOfRows == 2)
        #expect(browser.navigated.isEmpty)

        browserView.crumbButtons[1].performClick(nil)
        #expect(browser.navigated == ["/home"])

        browserView.tableView.selectRowIndexes([0], byExtendingSelection: false)
        browserView.rowDoubleClicked(nil)
        #expect(browser.opened == [0])
    }

    @Test func closingTheFilesTabClosesTheMockBrowser() {
        let controller = makeController()
        let browser = MockFileBrowser()
        let browserView = SftpBrowserView(model: browser)
        let filesTabID = "\(linuxVM.id)#files"
        controller.sessionTabs.openSession(identifier: filesTabID, title: "Files", content: browserView)

        browserView.closeButton.performClick(nil)
        controller.sessionTabs.closeSession(identifier: filesTabID)

        #expect(browser.closed)
        #expect(!controller.sessionTabs.sessionIdentifiers.contains(filesTabID))
    }
}

// MARK: - 4. Generate Windows credentials con API mockeada

@Suite("Flujo crítico: generate credentials (GH-66)")
@MainActor
struct CriticalGenerateCredentialsFlowTests {
    /// Vault en memoria (sustituye al Keychain real que usa la App).
    private final class MemoryVault: WindowsCredentialVault, @unchecked Sendable {
        private var stored: [String: WindowsLogonCredential] = [:]
        func load(for instance: InstanceInfo) throws -> WindowsLogonCredential? { stored[instance.id] }
        func save(_ credential: WindowsLogonCredential, for instance: InstanceInfo) throws {
            stored[instance.id] = credential
        }
    }

    @Test func menuTriggersEndToEndGenerationAgainstAMockedAPI() async throws {
        let controller = makeController()
        let vault = MemoryVault()
        var apiCalls: [(InstanceInfo, String)] = []
        // "API GCE mockeada": en lugar de resetear la contraseña vía Compute,
        // devuelve una fija sin red, igual que `WindowsCredentialCoordinatorTests`.
        let coordinator = WindowsCredentialCoordinator(vault: vault) { instance, username in
            apiCalls.append((instance, username))
            return WindowsLogonCredential(username: username, password: "mock-pw-1")
        }

        var requestedInstances: [InstanceInfo] = []
        controller.onGenerateWindowsCredentialsRequest = { instance in
            requestedInstances.append(instance)
        }

        let item = try #require(ExplorerWindowController.contextMenuItems(
            for: .instance(windowsVM), target: controller, windowsCredentialsAvailable: true)
            .first { $0.title == ExplorerCommand.generateWindowsCredentials.title })
        let action = try #require(item.action)
        _ = (item.target as? NSObject)?.perform(action, with: item)

        #expect(requestedInstances == [windowsVM])
        #expect(coordinator.stored(for: windowsVM) == nil)  // la App todavía no generó

        let generated = try await coordinator.generate(for: windowsVM, username: "ada")

        #expect(apiCalls.map(\.1) == ["ada"])
        #expect(generated.credential.password == "mock-pw-1")
        #expect(generated.persisted)
        #expect(coordinator.stored(for: windowsVM) == WindowsLogonCredential(username: "ada", password: "mock-pw-1"))
    }

    @Test func linuxInstancesNeverOfferTheMenuItem() {
        #expect(!ExplorerContextMenu.entries(for: .instance(linuxVM)).contains(.command(.generateWindowsCredentials)))
    }

    @Test func mockedApiFailureKeepsNoCredentialStored() async throws {
        struct MockApiFailure: Error {}
        let vault = MemoryVault()
        let coordinator = WindowsCredentialCoordinator(vault: vault) { _, _ in throw MockApiFailure() }

        await #expect(throws: MockApiFailure.self) {
            try await coordinator.generate(for: windowsVM, username: "ada")
        }
        #expect(coordinator.stored(for: windowsVM) == nil)
    }
}
