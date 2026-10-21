// GH-94: forwarder loopback + Connect RDP (research §9.5 (3)).
import Foundation
import Network
import RDPBridge
import Testing
import TunnelKit
@testable import BastionKit

/// Cliente TCP local mínimo (lo que haría Windows App).
private final class LocalClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "bastion.tests.client")

    init(port: UInt16) async throws {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { resume.resume() }
                case .failed(let error): if once.claim() { resume.resume(throwing: error) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { resume.resume(throwing: error) } else { resume.resume() }
            })
        }
    }

    /// Exactamente `count` bytes, o lo que llegue antes del EOF.
    func receive(count: Int) async -> Data {
        var data = Data()
        while data.count < count {
            let chunk: Data? = await withCheckedContinuation { resume in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - data.count) { chunk, _, done, error in
                    if let chunk, !chunk.isEmpty { resume.resume(returning: chunk) }
                    else { resume.resume(returning: (done || error != nil) ? nil : Data()) }
                }
            }
            guard let chunk else { break }
            data.append(chunk)
        }
        return data
    }

    func close() { connection.cancel() }
}

@MainActor
private final class FakeLauncher: WindowsAppLaunching {
    private(set) var launched: [String] = []

    func open(_ fileURL: URL) async throws(RdpError) {
        launched.append((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
    }
}

@Suite(.serialized)
struct BastionLocalForwarderTests {
    @Test func listensOnLoopbackAndForwardsBytes() async throws {
        let server = try await FakeBastionServer.start(.echo)
        defer { Task { await server.shutdown() } }
        let http = StubBastionHTTP()
        let forwarder = try await BastionLocalForwarder.start(factory: makeFactory(server: server, http: http))

        let client = try await LocalClient(port: forwarder.port)
        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
        try await client.send(payload)
        #expect(await client.receive(count: payload.count) == payload)
        #expect(server.observed.frameSizes.allSatisfy { $0 <= 4096 })

        client.close()
        await forwarder.stop()
        let stats = forwarder.statistics
        #expect(stats.connections == 1)
        #expect(stats.bytesUp == UInt64(payload.count))
        #expect(stats.bytesDown == UInt64(payload.count))
        #expect(await eventually { http.deleteRequests.count == 1 })
    }

    @Test func twoConcurrentConnectionsChainAndDeleteOnceAtTheEnd() async throws {
        let server = try await FakeBastionServer.start(.echo)
        defer { Task { await server.shutdown() } }
        let http = StubBastionHTTP()
        let forwarder = try await BastionLocalForwarder.start(factory: makeFactory(server: server, http: http))

        let first = try await LocalClient(port: forwarder.port)
        try await first.send(Data("a".utf8))
        #expect(await first.receive(count: 1) == Data("a".utf8))
        let second = try await LocalClient(port: forwarder.port)
        try await second.send(Data("b".utf8))
        #expect(await second.receive(count: 1) == Data("b".utf8))

        let posts = http.postRequests
        #expect(posts.count == 2)
        #expect(posts[1].form["token"] == Secrets.authToken(1))
        #expect(posts[1].headers["X-Node-Id"] == "node-7")
        #expect(server.observed.handshakes.count == 2)

        first.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(http.deleteRequests.isEmpty)  // queda una conexión viva

        second.close()
        #expect(await eventually { http.deleteRequests.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        await forwarder.stop()
        #expect(http.deleteRequests.count == 1)
    }

    @Test func stopDeletesTheSessionOfLiveConnections() async throws {
        let server = try await FakeBastionServer.start(.echo)
        defer { Task { await server.shutdown() } }
        let http = StubBastionHTTP()
        let forwarder = try await BastionLocalForwarder.start(factory: makeFactory(server: server, http: http))
        let client = try await LocalClient(port: forwarder.port)
        try await client.send(Data([7]))
        _ = await client.receive(count: 1)

        await forwarder.stop()
        #expect(http.deleteRequests.count == 1)
        #expect(await client.receive(count: 1).isEmpty)  // el cliente ve el cierre
    }

    @Test func failedTunnelClosesTheClientAndRecordsTheError() async throws {
        let server = try await FakeBastionServer.start(.echo)
        defer { Task { await server.shutdown() } }
        let http = StubBastionHTTP(postStatus: 403)
        let forwarder = try await BastionLocalForwarder.start(factory: makeFactory(server: server, http: http))
        let client = try await LocalClient(port: forwarder.port)

        #expect(await client.receive(count: 1).isEmpty)
        #expect(await eventually { forwarder.statistics.lastError == .unauthorized(message: nil) })
        #expect(forwarder.statistics.failedConnections == 1)
        await forwarder.stop()
    }

    /// GH-95: si el WebSocket cae a mitad de sesión, el TCP local muere enseguida
    /// (sin hang) y la UI recibe el error tipado.
    @Test func droppedWebSocketKillsTheTcpClientAndPublishesTheTypedError() async throws {
        let server = try await FakeBastionServer.start(.dropAfter(.milliseconds(300)))
        defer { Task { await server.shutdown() } }
        let http = StubBastionHTTP()
        let forwarder = try await BastionLocalForwarder.start(factory: makeFactory(server: server, http: http))
        var failures = forwarder.failures().makeAsyncIterator()

        let client = try await LocalClient(port: forwarder.port)
        try await client.send(Data("hola".utf8))
        #expect(await client.receive(count: 4) == Data("hola".utf8))
        // Tras el corte, el cliente ve EOF/reset en vez de quedarse esperando.
        #expect(await client.receive(count: 1).isEmpty)
        #expect(await failures.next() == .connectionLost(code: nil))
        #expect(forwarder.statistics.lastError == .connectionLost(code: nil))
        #expect(await eventually { http.deleteRequests.count == 1 })

        client.close()
        await forwarder.stop()
    }

    @Test func onlyLoopbackClientsAreAllowed() {
        let loopback = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 50_000)
        let lan = NWEndpoint.hostPort(host: "192.168.1.20", port: 50_000)
        #expect(IapListener.isClientAllowed(loopback))
        #expect(!IapListener.isClientAllowed(lan))
    }

    /// Connect RDP: el conector fallback existente escribe el `.rdp` contra el
    /// puerto del forwarder y lanza Windows App (aquí, un doble).
    @MainActor
    @Test func rdpConnectWritesLoopbackRdpFileAndLaunchesWindowsApp() async throws {
        let server = try await FakeBastionServer.start(.echo)
        defer { Task { await server.shutdown() } }
        let http = StubBastionHTTP()
        let rdpTarget = BastionTarget(dnsName: target.dnsName, vmResourceID: vmID, port: 3389)
        let tunnels = BastionRdpTunnels { _, remotePort in
            #expect(remotePort == 3389)
            return makeFactory(server: server, http: http, target: rdpTarget)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bastion-rdp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = FakeLauncher()
        let connector = RdpFallbackConnector(tunnels: tunnels, launcher: launcher, directory: directory)

        let launch = try await connector.connect(
            to: RdpTarget(project: "sub-1", zone: "rg-1", instance: "vm-win"),
            parameters: RdpParameters(), credential: RdpCredentialReference(username: "azureuser"))

        let contents = try #require(launcher.launched.first)
        #expect(contents.contains("full address:s:127.0.0.1:\(launch.localPort)"))
        #expect(!contents.contains(Secrets.armToken))
        // Probe: POST + WS + DELETE antes de lanzar Windows App.
        #expect(http.postRequests.count == 1)
        #expect(http.postRequests[0].form["workloadHostPort"] == "3389")
        #expect(http.deleteRequests.count == 1)

        let client = try await LocalClient(port: launch.localPort)
        try await client.send(Data("rdp".utf8))
        #expect(await client.receive(count: 3) == Data("rdp".utf8))
        client.close()
        await connector.shutdown()
        #expect(await eventually { http.deleteRequests.count == 2 })
    }

    @Test func rdpProbeFailsFastWithTypedError() async throws {
        let server = try await FakeBastionServer.start(.reject(status: 403))
        defer { Task { await server.shutdown() } }
        let http = StubBastionHTTP()
        let tunnels = BastionRdpTunnels { _, _ in makeFactory(server: server, http: http) }
        await #expect(throws: BastionTunnelError.unauthorized(message: nil)) {
            _ = try await tunnels.openTunnel(to: RdpTarget(project: "s", zone: "r", instance: "v"), remotePort: 3389)
        }
    }
}
