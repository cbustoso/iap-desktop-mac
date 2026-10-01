// CBU-44: RelayStream + IapListener contra el MockIAPRelayServer real
// (WebSocket, framing v4 lado servidor, closes 4033/4047, handshakes 403/404).
import Foundation
import IAPTestSupport
import Network
import Testing
@testable import TunnelKit

private func endpoint(for server: MockIAPRelayServer) -> RelayEndpoint {
    RelayEndpoint(
        connectURL: { server.connectURL },
        reconnectURL: { sid, ack in server.reconnectURL(sid: sid, ack: ack) })
}

private let transport = NIOWebSocketTransport(userAgent: "relay-integration-test", connectTimeout: .seconds(5))

@Suite("RelayStream sobre MockIAPRelayServer", .serialized, .timeLimit(.minutes(1)))
struct RelayIntegrationTests {
    @Test func echoRoundTripAndAcks() async throws {
        let server = try await MockIAPRelayServer.start()
        let stream = try await RelayStream.connect(
            endpoint: endpoint(for: server), opener: transport, accessToken: { "test-token" })
        var incoming = stream.incoming().makeAsyncIterator()

        try await stream.send(Data("hola relay".utf8))
        var echoed = Data()
        while echoed.count < 10, let chunk = await incoming.next() { echoed += chunk }
        #expect(echoed == Data("hola relay".utf8))
        #expect(await eventually { await stream.unacknowledgedByteCount == 0 })

        let handshake = try #require(server.handshakes.first)
        #expect(handshake.hasBearerToken)  // el mock solo registra que hubo token
        await stream.close()
        try await server.shutdown()
    }

    @Test(arguments: [
        (MockIAPRelayServer.HandshakeFailure.forbidden, TunnelError.connectionDenied),
        (.notFound, .backendNotFound),
    ])
    func handshakeHttpErrorsAreTyped(failure: MockIAPRelayServer.HandshakeFailure, expected: TunnelError) async throws {
        let server = try await MockIAPRelayServer.start(.init(handshakeFailure: failure))
        await #expect(throws: expected) {
            _ = try await RelayStream.connect(endpoint: endpoint(for: server), opener: transport, accessToken: { "t" })
        }
        #expect(expected.helpTopic != nil)
        try await server.shutdown()
    }

    @Test(arguments: [
        (MockIAPRelayServer.RelayCloseCode.notAuthorized, TunnelError.connectionDenied),
        (.lookupFailed, .backendNotFound),
    ])
    func relayCloseCodesAreTyped(code: MockIAPRelayServer.RelayCloseCode, expected: TunnelError) async throws {
        let server = try await MockIAPRelayServer.start(.init(close: .init(code: code)))
        await #expect(throws: expected) {
            _ = try await RelayStream.connect(endpoint: endpoint(for: server), opener: transport, accessToken: { "t" })
        }
        try await server.shutdown()
    }

    @Test func listenerForwardsTcpThroughRelay() async throws {
        let server = try await MockIAPRelayServer.start()  // eco
        let relayEndpoint = endpoint(for: server)
        let listener = try await IapListener.start {
            try await RelayStream.connect(endpoint: relayEndpoint, opener: transport, accessToken: { "t" })
        }
        let reply = try await tcpRoundTrip(port: listener.port, payload: Data("ping por túnel".utf8))
        #expect(reply == Data("ping por túnel".utf8))
        let stats = listener.statistics
        #expect(stats.connections == 1)
        #expect(stats.bytesUp >= 15 && stats.bytesDown >= 15)
        await listener.stop()
        try await server.shutdown()
    }

    @Test func listenerOnlyAcceptsLoopback() {
        #expect(IapListener.isClientAllowed(.hostPort(host: "127.0.0.1", port: 5000)))
        #expect(IapListener.isClientAllowed(.hostPort(host: "::1", port: 5000)))
        #expect(!IapListener.isClientAllowed(.hostPort(host: "192.168.1.20", port: 5000)))
    }
}

/// Cliente TCP mínimo: envía `payload` y lee hasta recibir la misma longitud.
private func tcpRoundTrip(port: UInt16, payload: Data) async throws -> Data {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.start(queue: .global())
    defer { connection.cancel() }
    try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
        connection.send(content: payload, completion: .contentProcessed { error in
            if let error { resume.resume(throwing: error) } else { resume.resume() }
        })
    }
    var received = Data()
    while received.count < payload.count {
        let chunk: Data? = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, _ in
                continuation.resume(returning: (data?.isEmpty == false) ? data : (isComplete ? nil : Data()))
            }
        }
        guard let chunk else { break }
        received += chunk
    }
    return received
}
