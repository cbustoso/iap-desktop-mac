import Foundation
import Testing
@testable import RDPBridge

private final class FakeTunnel: RdpTunnel, @unchecked Sendable {
    let localPort: UInt16
    private let lock = NSLock()
    private var closed = false
    init(localPort: UInt16) { self.localPort = localPort }
    var isClosed: Bool { lock.withLock { closed } }
    func close() async { lock.withLock { closed = true } }
}

/// `@unchecked`: estado bajo `lock`.
private final class FakeTunnels: RdpTunnelOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var nextPort: UInt16 = 51_234
    private(set) var opened: [(target: RdpTarget, remotePort: UInt16, tunnel: FakeTunnel)] = []
    var failure: (any Error)?

    func openTunnel(to target: RdpTarget, remotePort: UInt16) async throws -> any RdpTunnel {
        try lock.withLock {
            if let failure { throw failure }
            let tunnel = FakeTunnel(localPort: nextPort)
            nextPort += 1
            opened.append((target, remotePort, tunnel))
            return tunnel
        }
    }
}

@MainActor
private final class FakeLauncher: WindowsAppLaunching {
    var failure: RdpError?
    private(set) var launched: [(url: URL, contents: String)] = []

    func open(_ fileURL: URL) async throws(RdpError) {
        if let failure { throw failure }
        launched.append((fileURL, (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""))
    }
}

private let target = RdpTarget(project: "p", zone: "us-central1-a", instance: "win-1")

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("rdp-conn-\(UUID().uuidString)", isDirectory: true)
}

@Suite("RdpFallbackConnector (CBU-52)")
@MainActor
struct RdpFallbackConnectorTests {
    @Test func rdpFilePointsAtTunnelPortAndLaunches() async throws {
        let tunnels = FakeTunnels()
        let launcher = FakeLauncher()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connector = RdpFallbackConnector(tunnels: tunnels, launcher: launcher, directory: directory)

        let launch = try await connector.connect(
            to: target, parameters: RdpParameters(), credential: RdpCredentialReference(username: "ada"))

        #expect(tunnels.opened.map(\.remotePort) == [3389])  // túnel IAP al 3389 de la VM
        #expect(tunnels.opened.map(\.target) == [target])
        #expect(launch.localPort == 51_234)
        #expect(!launch.reusedTunnel)
        let contents = try #require(launcher.launched.first?.contents)
        #expect(contents.hasPrefix("full address:s:127.0.0.1:51234\r\n"))
        #expect(contents.contains("username:s:ada\r\n"))
        #expect(launcher.launched.first?.url == launch.fileURL)
        #expect(connector.activeTargets == [target])
    }

    @Test func customRemotePortIsTunneled() async throws {
        let tunnels = FakeTunnels()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var parameters = RdpParameters()
        parameters.port = 3390
        _ = try await RdpFallbackConnector(tunnels: tunnels, launcher: FakeLauncher(), directory: directory)
            .connect(to: target, parameters: parameters, credential: nil)
        #expect(tunnels.opened.map(\.remotePort) == [3390])
    }

    @Test func secondConnectReusesTunnel() async throws {
        let tunnels = FakeTunnels()
        let launcher = FakeLauncher()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connector = RdpFallbackConnector(tunnels: tunnels, launcher: launcher, directory: directory)
        _ = try await connector.connect(to: target, parameters: RdpParameters(), credential: nil)
        let again = try await connector.connect(to: target, parameters: RdpParameters(), credential: nil)
        #expect(tunnels.opened.count == 1)
        #expect(again.reusedTunnel)
        #expect(again.localPort == 51_234)
        #expect(launcher.launched.count == 2)
    }

    @Test func missingWindowsAppClosesTunnelAndDeletesFile() async throws {
        let tunnels = FakeTunnels()
        let launcher = FakeLauncher()
        launcher.failure = .windowsAppNotInstalled(help: RdpError.windowsAppHelp)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connector = RdpFallbackConnector(tunnels: tunnels, launcher: launcher, directory: directory)

        await #expect(throws: RdpError.windowsAppNotInstalled(help: RdpError.windowsAppHelp)) {
            try await connector.connect(to: target, parameters: RdpParameters(), credential: nil)
        }
        #expect(tunnels.opened.first?.tunnel.isClosed == true)
        #expect(connector.activeTargets.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func tunnelFailurePropagatesWithoutLaunching() async {
        struct Denied: Error, Equatable {}
        let tunnels = FakeTunnels()
        tunnels.failure = Denied()
        let launcher = FakeLauncher()
        let connector = RdpFallbackConnector(tunnels: tunnels, launcher: launcher, directory: temporaryDirectory())
        await #expect(throws: Denied()) {
            try await connector.connect(to: target, parameters: RdpParameters(), credential: nil)
        }
        #expect(launcher.launched.isEmpty)
    }

    @Test func invalidUsernameClosesNewTunnel() async {
        let tunnels = FakeTunnels()
        let connector = RdpFallbackConnector(tunnels: tunnels, launcher: FakeLauncher(), directory: temporaryDirectory())
        await #expect(throws: RdpError.invalidCredentialField("username")) {
            try await connector.connect(
                to: target, parameters: RdpParameters(), credential: RdpCredentialReference(username: "a\nb"))
        }
        #expect(tunnels.opened.first?.tunnel.isClosed == true)
    }

    @Test func shutdownClosesTunnelsAndRemovesFiles() async throws {
        let tunnels = FakeTunnels()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connector = RdpFallbackConnector(tunnels: tunnels, launcher: FakeLauncher(), directory: directory)
        let launch = try await connector.connect(to: target, parameters: RdpParameters(), credential: nil)
        #expect(FileManager.default.fileExists(atPath: launch.fileURL.path))
        await connector.shutdown()
        #expect(tunnels.opened.allSatisfy { $0.tunnel.isClosed })
        #expect(!FileManager.default.fileExists(atPath: launch.fileURL.path))
        #expect(connector.activeTargets.isEmpty)
    }

    /// Nada de contraseñas en disco: la credencial solo lleva usuario/dominio.
    @Test func generatedFilesNeverContainPasswords() async throws {
        let launcher = FakeLauncher()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await RdpFallbackConnector(tunnels: FakeTunnels(), launcher: launcher, directory: directory)
            .connect(to: target, parameters: RdpParameters(),
                     credential: RdpCredentialReference(username: "ada", domain: "CORP"))
        let mirror = Mirror(reflecting: RdpCredentialReference(username: "u"))
        #expect(mirror.children.compactMap(\.label) == ["username", "domain"])
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let text = try String(contentsOf: file, encoding: .utf8).lowercased()
            #expect(!text.contains("password"))
            #expect(!text.contains("pwd"))
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
    }
}

@Suite("WindowsUsername (CBU-52)")
struct WindowsUsernameTests {
    @Test func suggestsLocalPartUpTo20() {
        #expect(WindowsUsername.suggest(email: "ada.lovelace@example.com", fallback: "x") == "ada.lovelace")
        #expect(WindowsUsername.suggest(email: "abcdefghijklmnopqrstuvwxyz@x.com", fallback: "x") == "abcdefghijklmnopqrst")
        #expect(WindowsUsername.suggest(email: nil, fallback: "localuser") == "localuser")
        #expect(WindowsUsername.suggest(email: "@x.com", fallback: "fb") == "fb")
    }

    @Test func validatesLocalUsernames() {
        #expect(WindowsUsername.isValidLocal("ada"))
        #expect(WindowsUsername.isValidLocal("ada.lovelace"))
        #expect(!WindowsUsername.isValidLocal(""))
        #expect(!WindowsUsername.isValidLocal(String(repeating: "a", count: 21)))
        #expect(!WindowsUsername.isValidLocal("ada@example.com"))
        for bad in ["a/b", "a\\b", "a:b", "a b", "a\nb", "a*b", "a<b"] {
            #expect(!WindowsUsername.isValidLocal(bad), "\(bad)")
        }
    }
}
