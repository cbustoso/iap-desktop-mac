import Foundation
import Testing
@testable import RDPBridge

// GH-75: los settings efectivos (lo editado en Settings) llegan al `.rdp`.

/// Settings ya resueltos por ámbito, como los entrega la jerarquía de la App.
private struct StubSource: RdpSettingsSource {
    var values: [String: RdpSettingValue] = [:]
    var failing: Set<String> = []

    func value(forKey key: String) throws -> RdpSettingValue? {
        if failing.contains(key) { throw CocoaError(.coderReadCorrupt) }
        return values[key]
    }
}

private func rdp(_ settings: RdpEffectiveSettings, username: String? = nil) throws -> String {
    try RdpFileGenerator.contents(
        parameters: settings.parameters, credential: settings.credential(username: username), localPort: 51_234)
}

@Suite("RDP effective settings (GH-75)")
struct RdpSettingsTests {
    @Test func withoutSettingsEverythingStaysDefault() throws {
        let settings = RdpEffectiveSettings.resolve(from: StubSource())
        #expect(settings.parameters == RdpParameters())
        #expect(settings.username == nil && settings.domain == nil)
        #expect(settings.ignoredKeys.isEmpty)
        #expect(try rdp(settings)
            == RdpFileGenerator.contents(parameters: RdpParameters(), credential: nil, localPort: 51_234))
    }

    @Test func nonDefaultPortNlaAndRedirectionsReachTheRdpFile() throws {
        let settings = RdpEffectiveSettings.resolve(from: StubSource(values: [
            RdpSettingKey.port: .integer(3390),
            RdpSettingKey.networkLevelAuthentication: .integer(RdpNetworkLevelAuthentication.disabled.rawValue),
            RdpSettingKey.redirectClipboard: .bool(false),  // toggle del panel Settings
            RdpSettingKey.redirectPrinter: .integer(1),
            RdpSettingKey.redirectDrive: .integer(1),
            RdpSettingKey.redirectSmartCard: .bool(true),
            RdpSettingKey.colorDepth: .integer(RdpColorDepth.deepColor32.rawValue),
            RdpSettingKey.connectionBar: .integer(RdpConnectionBarState.pinned.rawValue),
            RdpSettingKey.sessionType: .integer(RdpSessionType.admin.rawValue),
        ]))
        #expect(settings.ignoredKeys.isEmpty)
        #expect(settings.parameters.port == 3390)
        let file = try rdp(settings)
        #expect(file.contains("enablecredsspsupport:i:0\r\n"))
        #expect(file.contains("redirectclipboard:i:0\r\n"))
        #expect(file.contains("redirectprinters:i:1\r\n"))
        #expect(file.contains("drivestoredirect:s:*\r\n"))
        #expect(file.contains("redirectsmartcards:i:1\r\n"))
        #expect(file.contains("session bpp:i:32\r\n"))
        #expect(file.contains("pinconnectionbar:i:1\r\n"))
        #expect(file.contains("administrative session:i:1\r\n"))
        #expect(file.hasPrefix("full address:s:127.0.0.1:51234\r\n"))  // el .rdp apunta al túnel local
    }

    @Test func everyParameterIsMappedFromItsSettingKey() {
        let settings = RdpEffectiveSettings.resolve(from: StubSource(values: [
            RdpSettingKey.connectionTimeout: .integer(45),
            RdpSettingKey.authenticationLevel: .integer(0),
            RdpSettingKey.audioPlayback: .integer(2),
            RdpSettingKey.audioInput: .integer(1),
            RdpSettingKey.automaticLogon: .integer(2),
            RdpSettingKey.redirectPort: .integer(1),
            RdpSettingKey.redirectDevice: .integer(1),
            RdpSettingKey.redirectWebAuthn: .integer(0),
            RdpSettingKey.hookWindowsKeys: .integer(0),
            RdpSettingKey.restrictedAdminMode: .integer(1),
            RdpSettingKey.dpiScaling: .integer(0),
            RdpSettingKey.desktopSize: .integer(1),
        ]))
        var expected = RdpParameters()
        expected.connectionTimeout = 45
        expected.authenticationLevel = .attemptServerAuthentication
        expected.audioPlayback = .doNotPlay
        expected.audioInput = .enabled
        expected.automaticLogon = .disabled
        expected.redirectPort = .enabled
        expected.redirectDevice = .enabled
        expected.redirectWebAuthn = .disabled
        expected.hookWindowsKeys = .disabled
        expected.restrictedAdminMode = .enabled
        expected.dpiScaling = .disabled
        expected.desktopSize = .screenSize
        #expect(settings.parameters == expected)
        #expect(settings.ignoredKeys.isEmpty)
    }

    @Test func usernameAndDomainFromSettingsGoToTheRdpFile() throws {
        let settings = RdpEffectiveSettings.resolve(from: StubSource(values: [
            RdpSettingKey.username: .text(" ada "),
            RdpSettingKey.domain: .text("CORP"),
        ]))
        #expect(settings.credential() == RdpCredentialReference(username: "ada", domain: "CORP"))
        let file = try rdp(settings)
        #expect(file.contains("username:s:ada\r\ndomain:s:CORP\r\n"))
        // Una credencial generada/guardada manda sobre el usuario de settings; el dominio se mantiene.
        #expect(settings.credential(username: "admin2") == RdpCredentialReference(username: "admin2", domain: "CORP"))
        #expect(!(try rdp(settings, username: "admin2")).contains("username:s:ada"))
    }

    @Test func emptyUsernameMeansNoCredentialLine() throws {
        let settings = RdpEffectiveSettings.resolve(from: StubSource(values: [
            RdpSettingKey.username: .text("  "), RdpSettingKey.domain: .text(""),
        ]))
        #expect(settings.credential() == nil)
        #expect(settings.credential(username: "") == nil)
        #expect(!(try rdp(settings)).contains("username:s:"))
    }

    @Test func invalidValuesFallBackToDefaultsAndAreReported() {
        let settings = RdpEffectiveSettings.resolve(from: StubSource(
            values: [
                RdpSettingKey.port: .integer(70_000),
                RdpSettingKey.networkLevelAuthentication: .integer(7),
                RdpSettingKey.colorDepth: .text("deep"),
                RdpSettingKey.username: .integer(5),
                RdpSettingKey.connectionTimeout: .integer(0),
            ],
            failing: [RdpSettingKey.redirectClipboard]))
        #expect(settings.parameters == RdpParameters())
        #expect(settings.username == nil)
        #expect(Set(settings.ignoredKeys) == [
            RdpSettingKey.port, RdpSettingKey.networkLevelAuthentication, RdpSettingKey.colorDepth,
            RdpSettingKey.username, RdpSettingKey.connectionTimeout, RdpSettingKey.redirectClipboard,
        ])
    }

    @Test func passwordIsNeverReadIntoEffectiveSettings() throws {
        let settings = RdpEffectiveSettings.resolve(from: StubSource(values: [
            RdpSettingKey.username: .text("ada"),
            RdpSettingKey.password: .text("hunter2-secret"),
        ]))
        #expect(!String(describing: settings).contains("hunter2-secret"))
        #expect(!(try rdp(settings)).contains("hunter2-secret"))
    }
}

/// Por el conector: el túnel va al puerto de settings y el `.rdp` lanzado los lleva.
@Suite("RDP settings through the connector (GH-75)")
@MainActor
struct RdpSettingsConnectorTests {
    private final class Tunnels: RdpTunnelOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var ports: [UInt16] = []
        var remotePorts: [UInt16] { lock.withLock { ports } }
        func openTunnel(to target: RdpTarget, remotePort: UInt16) async throws -> any RdpTunnel {
            lock.withLock { ports.append(remotePort) }
            return Tunnel()
        }
    }

    private final class Tunnel: RdpTunnel {
        var localPort: UInt16 { 50_001 }
        func close() async {}
    }

    private final class Launcher: WindowsAppLaunching {
        var contents: [String] = []
        func open(_ fileURL: URL) async throws(RdpError) {
            contents.append((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
        }
    }

    @Test func connectorUsesSettingsPortAndWritesThemToTheLaunchedFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdp-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tunnels = Tunnels()
        let launcher = Launcher()
        let settings = RdpEffectiveSettings.resolve(from: StubSource(values: [
            RdpSettingKey.port: .integer(13_389),
            RdpSettingKey.networkLevelAuthentication: .bool(false),
            RdpSettingKey.redirectClipboard: .bool(false),
            RdpSettingKey.username: .text("ada"),
        ]))
        _ = try await RdpFallbackConnector(tunnels: tunnels, launcher: launcher, directory: directory).connect(
            to: RdpTarget(project: "p", zone: "z", instance: "win-1"),
            parameters: settings.parameters, credential: settings.credential())
        #expect(tunnels.remotePorts == [13_389])
        let file = try #require(launcher.contents.first)
        #expect(file.hasPrefix("full address:s:127.0.0.1:50001\r\nusername:s:ada\r\n"))
        #expect(file.contains("enablecredsspsupport:i:0\r\n"))
        #expect(file.contains("redirectclipboard:i:0\r\n"))
    }
}
