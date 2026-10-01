// TunnelKit CBU-27 tests: MockIAPRelayServer (specs/tunnel/mock-server.md).
// Los vectores de bytes son literales a propósito: no reutilizan el encoder del mock.
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import IAPTestSupport
import Testing
import WebSocketKit
@testable import TunnelKit

// MARK: - Helpers

/// Cliente WebSocket crudo (WebSocketKit) para ver close codes y controlar
/// cabeceras; `RelayChannel` de producto aún no expone el close code (T-TUN-4).
private final class RawRelayClient: Sendable {
    let socket: WebSocket
    let messages: AsyncStream<[UInt8]>
    private let group: MultiThreadedEventLoopGroup

    private init(socket: WebSocket, messages: AsyncStream<[UInt8]>, group: MultiThreadedEventLoopGroup) {
        self.socket = socket
        self.messages = messages
        self.group = group
    }

    static func connect(
        _ url: URL,
        origin: String? = MockIAPRelayServer.relayOrigin,
        subprotocol: String? = MockIAPRelayServer.relaySubprotocol
    ) async throws -> RawRelayClient {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        var headers = HTTPHeaders([("Authorization", "Bearer test-token")])
        if let origin { headers.add(name: "Origin", value: origin) }
        if let subprotocol { headers.add(name: "Sec-WebSocket-Protocol", value: subprotocol) }
        do {
            let socket: WebSocket = try await withCheckedThrowingContinuation { resume in
                WebSocket.connect(to: url.absoluteString, headers: headers, on: group) { ws in
                    ws.onBinary { _, buffer in continuation.yield(Array(buffer.readableBytesView)) }
                    ws.onClose.whenComplete { _ in continuation.finish() }
                    resume.resume(returning: ws)
                }.whenFailure { resume.resume(throwing: $0) }
            }
            return RawRelayClient(socket: socket, messages: stream, group: group)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func send(_ bytes: [UInt8]) {
        socket.send(bytes, promise: nil)
    }

    /// Todos los mensajes hasta el cierre del servidor + close code recibido.
    func drainUntilClosed() async throws -> (messages: [[UInt8]], closeCode: WebSocketErrorCode?) {
        var received: [[UInt8]] = []
        for await message in messages { received.append(message) }
        try await socket.onClose.get()
        return (received, socket.closeCode)
    }

    func shutdown() async {
        if !socket.isClosed { _ = try? await socket.close().get() }
        try? await group.shutdownGracefully()
    }
}

/// Envía una petición de upgrade WebSocket real por TCP crudo y devuelve el
/// status HTTP exacto (WebSocketKit solo expone "falló", no el código).
private func upgradeStatus(
    _ url: URL,
    origin: String? = MockIAPRelayServer.relayOrigin,
    subprotocol: String? = MockIAPRelayServer.relaySubprotocol
) async throws -> Int {
    var request = "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
    if let origin { request += "Origin: \(origin)\r\n" }
    if let subprotocol { request += "Sec-WebSocket-Protocol: \(subprotocol)\r\n" }
    request += "\r\n"

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { group.shutdownGracefully { _ in } }
    let channel = try await ClientBootstrap(group: group)
        .connect(host: "127.0.0.1", port: url.port ?? 80) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
        }
    // El servidor cierra tras responder: el cierre final de `executeThenClose`
    // puede fallar (canal ya cerrado), así que la respuesta se guarda fuera.
    var response = ""
    do {
        try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(string: request))
            for try await chunk in inbound {
                response += String(buffer: chunk)
                if response.contains("\r\n") { break }  // basta la línea de estado
            }
        }
    } catch where !response.isEmpty {
        // Respuesta ya leída; el error es del cierre.
    }
    // "HTTP/1.1 403 Forbidden"
    let statusLine = response.split(separator: "\r\n").first ?? ""
    return Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? -1
}

private func closeCode(_ code: MockIAPRelayServer.RelayCloseCode) -> WebSocketErrorCode {
    WebSocketErrorCode(codeNumber: Int(code.rawValue))
}

/// `CONNECT_SUCCESS_SID` con "mock-session" (12 bytes).
private let connectSuccessMockSession: [UInt8] = [0, 1, 0, 0, 0, 12] + Array("mock-session".utf8)

// MARK: - Tests

@Suite("Mock IAP relay server", .timeLimit(.minutes(1)))
struct MockRelayServerTests {
    /// Demo de eco extremo a extremo con el transporte de producto.
    @Test func echoDemoOverProductTransport() async throws {
        let server = try await MockIAPRelayServer.start()
        let channel = try await NIOWebSocketTransport(userAgent: "mock-relay-test")
            .connect(to: server.connectURL, accessToken: "test-token")
        var incoming = channel.incoming().makeAsyncIterator()

        #expect(try #require(await incoming.next()) == Data(connectSuccessMockSession))

        let hello = Array("hello relay".utf8)  // 11 bytes
        try await channel.send(Data([0, 4, 0, 0, 0, 11] + hello))
        #expect(try #require(await incoming.next()) == Data([0, 4, 0, 0, 0, 11] + hello))
        #expect(try #require(await incoming.next()) == Data([0, 7, 0, 0, 0, 0, 0, 0, 0, 11]))

        // El ACK es acumulado: 11 + 5 = 16.
        try await channel.send(Data([0, 4, 0, 0, 0, 5] + Array("again".utf8)))
        _ = await incoming.next()
        #expect(try #require(await incoming.next()) == Data([0, 7, 0, 0, 0, 0, 0, 0, 0, 16]))

        let handshake = try #require(server.handshakes.first)
        #expect(handshake.path == "/v4/connect")
        #expect(handshake.origin == "bot:iap-tunneler")
        #expect(handshake.subprotocols.contains("relay.tunnel.cloudproxy.app"))
        #expect(handshake.hasBearerToken)
        #expect(handshake.upgraded)

        await channel.close()
        try await server.shutdown()
    }

    @Test(arguments: [
        (MockIAPRelayServer.HandshakeFailure.forbidden, 403),
        (.notFound, 404),
    ])
    func handshakeFailureModes(failure: MockIAPRelayServer.HandshakeFailure, status: Int) async throws {
        let server = try await MockIAPRelayServer.start(.init(handshakeFailure: failure))
        #expect(try await upgradeStatus(server.connectURL) == status)
        #expect(server.handshakes.map(\.upgraded) == [false])
        try await server.shutdown()
    }

    /// El transporte de producto falla (no cuelga) ante 403/404. Hoy lanza
    /// `.handshakeFailed`; T-TUN-4 lo afinará a `.connectionDenied` / `.backendNotFound`.
    @Test(arguments: [MockIAPRelayServer.HandshakeFailure.forbidden, .notFound])
    func transportFailsOnRejectedHandshake(failure: MockIAPRelayServer.HandshakeFailure) async throws {
        let server = try await MockIAPRelayServer.start(.init(handshakeFailure: failure))
        await #expect(throws: TunnelError.self) {
            _ = try await NIOWebSocketTransport().connect(to: server.connectURL, accessToken: "t")
        }
        try await server.shutdown()
    }

    @Test(arguments: [
        (origin: String?.none, subprotocol: Optional(MockIAPRelayServer.relaySubprotocol)),
        (origin: "https://evil.example", subprotocol: MockIAPRelayServer.relaySubprotocol),
        (origin: MockIAPRelayServer.relayOrigin, subprotocol: String?.none),
        (origin: MockIAPRelayServer.relayOrigin, subprotocol: "other.protocol"),
    ])
    func rejectsHandshakeWithoutRelayHeaders(origin: String?, subprotocol: String?) async throws {
        let server = try await MockIAPRelayServer.start()
        #expect(try await upgradeStatus(server.connectURL, origin: origin, subprotocol: subprotocol) == 400)
        #expect(server.handshakes.map(\.upgraded) == [false])
        try await server.shutdown()
    }

    @Test func acceptsHandshakeWithRelayHeaders() async throws {
        let server = try await MockIAPRelayServer.start()
        #expect(try await upgradeStatus(server.connectURL) == 101)
        try await server.shutdown()
    }

    @Test(arguments: [
        MockIAPRelayServer.RelayCloseCode.notAuthorized,
        .lookupFailed,
        .failedToRewind,
    ])
    func closeCodeOnConnect(code: MockIAPRelayServer.RelayCloseCode) async throws {
        let server = try await MockIAPRelayServer.start(.init(close: .init(code: code)))
        let client = try await RawRelayClient.connect(server.connectURL)
        let (messages, received) = try await client.drainUntilClosed()
        #expect(messages.isEmpty)  // denegado antes de CONNECT_SUCCESS_SID
        #expect(received == closeCode(code))
        await client.shutdown()
        try await server.shutdown()
    }

    @Test func closeMidSessionWithLongClose() async throws {
        let server = try await MockIAPRelayServer.start(.init(close: .init(
            code: .failedToRewind, reason: "Fail", afterSessionID: true, sendLongClose: true)))
        let client = try await RawRelayClient.connect(server.connectURL)
        let (messages, received) = try await client.drainUntilClosed()
        #expect(messages == [
            connectSuccessMockSession,
            [0, 10, 0, 0, 0x0F, 0xEA, 0, 0, 0, 4] + Array("Fail".utf8),  // LONG_CLOSE 4074
        ])
        #expect(received == closeCode(.failedToRewind))
        await client.shutdown()
        try await server.shutdown()
    }

    @Test func reconnectReturnsAckAndRecordsQuery() async throws {
        let server = try await MockIAPRelayServer.start(.init(sessionID: "sid-1", reconnectAck: 42))
        let client = try await RawRelayClient.connect(server.reconnectURL(sid: "sid-1", ack: 7))
        var iterator = client.messages.makeAsyncIterator()
        #expect(await iterator.next() == [0, 2, 0, 0, 0, 0, 0, 0, 0, 42])

        let handshake = try #require(server.handshakes.first)
        #expect(handshake.path == "/v4/reconnect")
        #expect(handshake.query["sid"] == "sid-1")
        #expect(handshake.query["ack"] == "7")
        await client.shutdown()
        try await server.shutdown()
    }

    @Test func reconnectWithUnknownSidCloses4001() async throws {
        let server = try await MockIAPRelayServer.start(.init(sessionID: "sid-1"))
        let client = try await RawRelayClient.connect(server.reconnectURL(sid: "other", ack: 0))
        let (messages, received) = try await client.drainUntilClosed()
        #expect(messages.isEmpty)
        #expect(received == closeCode(.sidUnknown))
        await client.shutdown()
        try await server.shutdown()
    }

    @Test(arguments: [
        [0, 99] as [UInt8],  // tag desconocido
        [0, 4, 0, 0, 0, 5, 0x41],  // DATA con longitud que no cuadra
        [0, 4, 0, 0, 0, 0],  // DATA vacío
        [0],  // truncado
    ])
    func malformedMessageCloses4008(message: [UInt8]) async throws {
        let server = try await MockIAPRelayServer.start()
        let client = try await RawRelayClient.connect(server.connectURL)
        client.send(message)
        let (messages, received) = try await client.drainUntilClosed()
        #expect(messages == [connectSuccessMockSession])
        #expect(received == WebSocketErrorCode(codeNumber: 4008))  // INVALID_TAG
        await client.shutdown()
        try await server.shutdown()
    }
}
