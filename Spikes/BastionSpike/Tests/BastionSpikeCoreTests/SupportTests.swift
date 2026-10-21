import Foundation
import Network
import Testing
@testable import BastionSpikeCore

@Suite("az, redacción, CLI, RDP y listener")
struct SupportTests {
    static let tokenJSON = #"{"accessToken":"eyJ0eXAiOiJKV1QiLCJhbGciOi.secret.sig","expires_on":4102444800,"tenant":"tenant-a","subscription":"sub-1","tokenType":"Bearer"}"#

    @Test("AzTokenProvider: argumentos exactos y caché por tenant")
    func tokenCachePerTenant() async throws {
        let az = FakeAz { _ in AzCommandOutput(exitCode: 0, stdout: Data(Self.tokenJSON.utf8), stderr: Data()) }
        let provider = AzTokenProvider(runner: az, log: LogCapture().makeLog())

        let token = try await provider.token(tenant: "tenant-a")
        _ = try await provider.token(tenant: "tenant-a")
        _ = try await provider.token(tenant: "tenant-b")

        #expect(token.accessToken == "eyJ0eXAiOiJKV1QiLCJhbGciOi.secret.sig")
        #expect(token.expiresOn == Date(timeIntervalSince1970: 4_102_444_800))
        #expect(az.invocations.count == 2)
        #expect(az.invocations[0] == ["account", "get-access-token", "--resource", "https://management.core.windows.net/", "--tenant", "tenant-a", "--output", "json"])
        #expect(!token.description.contains("secret"))
    }

    @Test("AzTokenProvider: renueva cuando el token está a punto de expirar")
    func tokenRefreshNearExpiry() async throws {
        let soon = #"{"accessToken":"short-lived-token-1","expires_on":"1000","tenant":"t"}"#
        let az = FakeAz { _ in AzCommandOutput(exitCode: 0, stdout: Data(soon.utf8), stderr: Data()) }
        let provider = AzTokenProvider(runner: az, now: { Date(timeIntervalSince1970: 900) }, log: LogCapture().makeLog())
        _ = try await provider.token(tenant: nil)
        _ = try await provider.token(tenant: nil)
        #expect(az.invocations.count == 2)
        #expect(!az.invocations[0].contains("--tenant"))
    }

    @Test("az sin sesión → notLoggedIn; account list vacío → notLoggedIn")
    func notLoggedIn() async {
        let az = FakeAz { arguments in
            if arguments.contains("list") { return AzCommandOutput(exitCode: 0, stdout: Data("[]".utf8), stderr: Data()) }
            return AzCommandOutput(exitCode: 1, stdout: Data(), stderr: Data("ERROR: Please run 'az login' to setup account.".utf8))
        }
        let provider = AzTokenProvider(runner: az, log: LogCapture().makeLog())
        await #expect(throws: AzCliError.notLoggedIn(tenant: "t1")) { try await provider.token(tenant: "t1") }
        await #expect(throws: AzCliError.notLoggedIn(tenant: nil)) { try await provider.accounts() }
    }

    @Test("Logs: aztoken, authToken y websocketToken nunca aparecen")
    func logsAreRedacted() async throws {
        let capture = LogCapture()
        let log = capture.makeLog()
        let az = FakeAz { _ in AzCommandOutput(exitCode: 0, stdout: Data(Self.tokenJSON.utf8), stderr: Data()) }
        let provider = AzTokenProvider(runner: az, log: log)
        let plane = BastionDataPlane(dnsName: "bst-1.bastion.azure.com", transport: FakeHTTP.bastion(), log: log)
        let manager = BastionSessionManager(dataPlane: plane, resourceID: "/subscriptions/s/vm", port: 22, log: log) {
            try await provider.token(tenant: "tenant-a").accessToken
        }

        let tokens = try await manager.open()
        log.info("WS \(WebSocketRequest.bastion(dnsName: plane.dnsName, tokens: tokens))")
        log.info("eco accidental: \(tokens.websocketToken) \(tokens.authToken)")
        await manager.release()

        let text = capture.text
        #expect(text.contains("POST https://bst-1.bastion.azure.com/api/tokens"))
        #expect(text.contains("DELETE"))
        #expect(!text.contains("eyJ0eXAiOiJKV1QiLCJhbGciOi.secret.sig"))
        #expect(!text.contains("ws-token-secret-0"))
        #expect(!text.contains("auth-token-0"))
        #expect(text.contains("aztoken=<redacted:"))
    }

    @Test("CLI: flags, valores por defecto y errores")
    func parseOptions() throws {
        let options = try SpikeOptions.parse([
            "--subscription", "s", "--resource-group", "rg", "--bastion", "bh", "--vm", "vm1",
            "--mode", "rdp", "--listen-port", "53389",
        ])
        #expect(options.targetPort == 3389)
        #expect(options.listenPort == 53_389)
        #expect(options.vmResourceID == "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1")
        #expect(options.bastionResourceID == "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/bastionHosts/bh")

        let ssh = try SpikeOptions.parse(["--subscription", "s", "--resource-group", "rg", "--bastion", "bh", "--vm", "/subscriptions/x/vm", "--port", "2222"])
        #expect(ssh.mode == .ssh)
        #expect(ssh.targetPort == 2222)
        #expect(ssh.vmResourceID == "/subscriptions/x/vm")

        #expect(try SpikeOptions.parse(["--list-accounts"]).command == .listAccounts)
        #expect(throws: SpikeOptions.ParseError.self) { try SpikeOptions.parse(["--vm", "x"]) }
        #expect(throws: SpikeOptions.ParseError.self) { try SpikeOptions.parse(["--mode", "vnc"]) }
    }

    @Test(".rdp temporal apunta al listener local")
    func rdpFile() throws {
        let file = try RDPLauncher.writeTemporaryFile(port: 53_389, username: "azureuser")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.hasPrefix("full address:s:127.0.0.1:53389\r\n"))
        #expect(contents.contains("username:s:azureuser"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test("Listener real en 127.0.0.1 + bombeo contra un WebSocket falso (eco)")
    func listenerEndToEnd() async throws {
        let socket = FakeSocket(echoChunk: 700)
        let listener = try LocalListener(port: 0)
        let port = try await listener.start { stream in
            Task { _ = await TunnelPump.run(local: stream, socket: socket) }
        }
        defer { listener.stop() }
        #expect(port > 0)

        let client = NWConnectionStream(
            connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp),
            queue: DispatchQueue(label: "test.client")
        )
        let message = TunnelPumpTests.payload(5_000)
        try await client.send(message)
        var echoed = Data()
        while echoed.count < message.count, let chunk = try await client.receive(maximum: 65_536) {
            echoed.append(chunk)
        }
        await client.close()

        #expect(echoed == message)
        #expect(socket.sentFrames.allSatisfy { $0.count <= TunnelPump.readChunk })
    }
}
