// GH-93: WebSocket del túnel contra el servidor falso (research §9.5 (2) y (4)).
import Foundation
import NIOPosix
import SSHKit
import Testing
@testable import BastionKit

/// Lee del stream hasta juntar `count` bytes (o fin).
private func collect(_ stream: BastionTunnelStream, count: Int) async -> Data {
    var data = Data()
    for await chunk in stream.incoming() {
        data.append(chunk)
        if data.count >= count { break }
    }
    return data
}

@Suite(.serialized)
struct BastionTunnelStreamTests {
    @Test func handshakeHasOnlyOriginAndRawPath() async throws {
        let server = try await FakeBastionServer.start()
        defer { Task { await server.shutdown() } }
        let stream = try await makeFactory(server: server, http: StubBastionHTTP()).openStream()
        await stream.close()

        let handshake = try #require(server.observed.handshakes.first)
        #expect(handshake.path == "/webtunnelv2/\(Secrets.websocketToken(1))")
        #expect(handshake.query == "X-Node-Id=node-7")
        #expect(handshake.origin == "https://bst-123.bastion.azure.com")
        #expect(!handshake.hasSubprotocol)
        #expect(!handshake.hasAuthorization)
    }

    @Test(arguments: [1, 4096, 4097, 1 << 20])
    func echoSplitsClientFramesAt4096(size: Int) async throws {
        let server = try await FakeBastionServer.start(.echo)
        defer { Task { await server.shutdown() } }
        let stream = try await makeFactory(server: server, http: StubBastionHTTP()).openStream()
        let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })

        async let echoed = collect(stream, count: size)
        try await stream.send(payload)
        #expect(await echoed == payload)

        let sizes = server.observed.frameSizes
        #expect(sizes.allSatisfy { $0 <= 4096 })
        #expect(sizes.reduce(0, +) == size)
        #expect(sizes.count == (size + 4095) / 4096)
        await stream.close()
        #expect(await stream.terminationError == nil)
    }

    @Test func clientCloseSends1000AndReleasesTheSessionOnce() async throws {
        let server = try await FakeBastionServer.start()
        defer { Task { await server.shutdown() } }
        let http = StubBastionHTTP()
        let factory = makeFactory(server: server, http: http)
        let stream = try await factory.openStream()
        #expect(await factory.activeSessions == 1)

        await stream.close()
        await stream.close()
        #expect(await factory.activeSessions == 0)
        #expect(http.deleteRequests.count == 1)
        #expect(await eventually { server.observed.clientCloseCodes == [1000] })
    }

    @Test func textFrameMeansProtocolChanged() async throws {
        let server = try await FakeBastionServer.start(.textOnFirstFrame)
        defer { Task { await server.shutdown() } }
        let stream = try await makeFactory(server: server, http: StubBastionHTTP()).openStream()
        try await stream.send(Data([1]))
        for await _ in stream.incoming() {}
        #expect(await eventually { await stream.terminationError == .protocolChanged(status: nil) })
    }

    @Test func serverClose1000IsCleanEOF() async throws {
        let server = try await FakeBastionServer.start(.closeOnFirstFrame(code: 1000))
        defer { Task { await server.shutdown() } }
        let stream = try await makeFactory(server: server, http: StubBastionHTTP()).openStream()
        try await stream.send(Data([1]))
        for await _ in stream.incoming() {}
        #expect(await eventually { await stream.isFinished })
        #expect(await stream.terminationError == nil)
    }

    @Test func abruptDropIsConnectionLost() async throws {
        let server = try await FakeBastionServer.start(.dropOnFirstFrame)
        defer { Task { await server.shutdown() } }
        let http = StubBastionHTTP()
        let factory = makeFactory(server: server, http: http)
        let stream = try await factory.openStream()
        let states = await stream.linkStates()
        try await stream.send(Data([1]))
        for await _ in stream.incoming() {}

        #expect(await eventually { await stream.terminationError == .connectionLost(code: nil) })
        var last: SshLinkState?
        for await state in states { last = state }
        #expect(last == .lost(.relayClosed(code: 1006)))
        #expect(await eventually { http.deleteRequests.count == 1 })
        await #expect(throws: BastionTunnelError.connectionLost(code: nil)) { try await stream.send(Data([2])) }
    }

    @Test(arguments: [
        (403, BastionTunnelError.unauthorized(message: nil)),
        (404, BastionTunnelError.targetNotFound),
        (500, BastionTunnelError.protocolChanged(status: 500)),
    ])
    func rejectedUpgradeIsTypedAndReleasesTheSession(status: Int, expected: BastionTunnelError) async throws {
        let server = try await FakeBastionServer.start(.reject(status: status))
        defer { Task { await server.shutdown() } }
        let http = StubBastionHTTP()
        let factory = makeFactory(server: server, http: http)
        await #expect(throws: expected) { try await factory.openStream() }
        #expect(await factory.activeSessions == 0)
        #expect(http.deleteRequests.count == 1)
    }

    @Test func unresponsiveServerTimesOut() async throws {
        // Un listener TCP que acepta y nunca contesta el upgrade.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let silent = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        defer {
            silent.close(promise: nil)
            Task { try? await group.shutdownGracefully() }
        }
        let transport = NIOBastionWebSocketTransport(
            connectTimeout: .milliseconds(300),
            endpointOverride: .init(scheme: "ws", host: "127.0.0.1", port: silent.localAddress?.port ?? 0))
        let session = BastionSessionClient.Session(authToken: "a", nodeID: "n", websocketToken: "w")
        await #expect(throws: BastionTunnelError.timeout) {
            try await transport.open(.tunnel(dnsName: "bst.example", session: session))
        }
    }
}
