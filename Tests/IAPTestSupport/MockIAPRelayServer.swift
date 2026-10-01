// Mock del relay IAP (SSH Relay v4) para tests de TunnelKit (specs/tunnel/mock-server.md).
// Port de `Google.Solutions.Iap.Test/Util/WebSocketServer.cs`. Solo tests, nunca producto.
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// Servidor WebSocket en `127.0.0.1:{puerto efímero}` que habla el lado
/// servidor del framing v4:
///
/// - Handshake: exige subprotocolo `relay.tunnel.cloudproxy.app` y
///   `Origin: bot:iap-tunneler` (si faltan → HTTP 400).
/// - `/v4/connect` → `CONNECT_SUCCESS_SID`; `/v4/reconnect?sid&ack` →
///   `RECONNECT_SUCCESS_ACK` (sid desconocido → close 4001).
/// - `DATA` → eco `DATA` + `ACK` acumulado de bytes recibidos.
/// - Modos de fallo: HTTP 403/404 en el handshake, o close WebSocket con
///   código 4033/4047/4074 tras el upgrade.
///
/// Los close codes viajan en el **close frame WebSocket**: es lo que el cliente
/// C# evalúa (`SshRelaySession`, `e.CloseStatus`); el mensaje `LONG_CLOSE`
/// se ignora allí y aquí solo se envía si se pide (`sendLongClose`).
public final class MockIAPRelayServer: Sendable {
    public static let relaySubprotocol = "relay.tunnel.cloudproxy.app"
    public static let relayOrigin = "bot:iap-tunneler"

    /// Fallo en el handshake HTTP (antes del upgrade).
    public enum HandshakeFailure: Sendable, Equatable {
        /// 403: p. ej. proxy corporativo que bloquea WebSocket.
        case forbidden
        /// 404: backend/instancia inexistente.
        case notFound

        public var status: HTTPResponseStatus {
            switch self {
            case .forbidden: return .forbidden
            case .notFound: return .notFound
            }
        }
    }

    /// Close codes del relay usados por el mock (nombres de `SshRelayCloseCode` C#).
    public enum RelayCloseCode: UInt16, Sendable, CaseIterable {
        case sidUnknown = 4001
        case notAuthorized = 4033
        case lookupFailed = 4047
        case failedToRewind = 4074
    }

    /// Cierre programado tras el upgrade.
    public struct CloseBehavior: Sendable {
        public var code: RelayCloseCode
        public var reason: String
        /// Enviar antes `CONNECT_SUCCESS_SID` (cierre a mitad de sesión) o
        /// cerrar directamente (denegado en el propio connect).
        public var afterSessionID: Bool
        /// Enviar también un mensaje `LONG_CLOSE` antes del close frame.
        public var sendLongClose: Bool

        public init(
            code: RelayCloseCode, reason: String = "mock relay close",
            afterSessionID: Bool = false, sendLongClose: Bool = false
        ) {
            self.code = code
            self.reason = reason
            self.afterSessionID = afterSessionID
            self.sendLongClose = sendLongClose
        }
    }

    /// Backend TCP al que el relay reenvía los DATA (como IAP hacia la VM).
    /// Sin backend, el relay hace eco (DATA → DATA + ACK).
    public struct Backend: Sendable, Equatable {
        public var host: String
        public var port: Int

        public init(host: String = "127.0.0.1", port: Int) {
            self.host = host
            self.port = port
        }
    }

    public struct Configuration: Sendable {
        public var handshakeFailure: HandshakeFailure?
        public var close: CloseBehavior?
        public var sessionID: String
        /// ACK que devuelve `RECONNECT_SUCCESS_ACK`.
        public var reconnectAck: UInt64
        public var backend: Backend?

        public init(
            handshakeFailure: HandshakeFailure? = nil,
            close: CloseBehavior? = nil,
            sessionID: String = "mock-session",
            reconnectAck: UInt64 = 0,
            backend: Backend? = nil
        ) {
            self.handshakeFailure = handshakeFailure
            self.close = close
            self.sessionID = sessionID
            self.reconnectAck = reconnectAck
            self.backend = backend
        }
    }

    /// Handshake recibido (para aserciones). Nunca guarda el token: solo si
    /// venía un `Authorization: Bearer …`.
    public struct Handshake: Sendable, Equatable {
        public var path: String
        public var query: [String: String]
        public var origin: String?
        public var subprotocols: [String]
        public var hasBearerToken: Bool
        public var upgraded: Bool
    }

    /// `ws://127.0.0.1:{port}` (añadir `/v4/connect` o `/v4/reconnect?...`).
    public let baseURL: URL
    public var connectURL: URL { baseURL.appendingPathComponent("v4/connect") }

    private let group: MultiThreadedEventLoopGroup
    private let serverChannel: any Channel
    private let log: HandshakeLog

    public var handshakes: [Handshake] { log.entries }

    public func reconnectURL(sid: String, ack: UInt64) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/v4/reconnect"
        components.queryItems = [URLQueryItem(name: "sid", value: sid), URLQueryItem(name: "ack", value: String(ack))]
        return components.url!
    }

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel, baseURL: URL, log: HandshakeLog) {
        self.group = group
        self.serverChannel = channel
        self.baseURL = baseURL
        self.log = log
    }

    public static func start(_ configuration: Configuration = .init()) async throws -> MockIAPRelayServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let log = HandshakeLog()
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .childChannelInitializer { channel in
                    configure(channel: channel, configuration: configuration, log: log)
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            guard let port = channel.localAddress?.port,
                  let baseURL = URL(string: "ws://127.0.0.1:\(port)")
            else {
                try? await channel.close()
                throw MockServerError.missingLocalPort
            }
            return MockIAPRelayServer(group: group, channel: channel, baseURL: baseURL, log: log)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func shutdown() async throws {
        try? await serverChannel.close()
        try await group.shutdownGracefully()
    }

    // MARK: - Pipeline

    private static func configure(
        channel: any Channel, configuration: Configuration, log: HandshakeLog
    ) -> EventLoopFuture<Void> {
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 20,
            shouldUpgrade: { channel, request in
                // nil → sin upgrade: la petición sigue hasta HTTPRejectionHandler.
                guard configuration.handshakeFailure == nil, hasRequiredHeaders(request.headers) else {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                return channel.eventLoop.makeSucceededFuture(
                    HTTPHeaders([("Sec-WebSocket-Protocol", relaySubprotocol)]))
            },
            upgradePipelineHandler: { channel, request in
                log.append(handshake(from: request, upgraded: true))
                // Se ejecuta en el event loop del canal: syncOperations evita
                // exigir Sendable a los handlers (que no lo son).
                return channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    let rejection = try pipeline.handler(type: HTTPRejectionHandler.self)
                    pipeline.removeHandler(rejection, promise: nil)
                    try pipeline.addHandlers(
                        NIOWebSocketFrameAggregator(
                            minNonFinalFragmentSize: 1,
                            maxAccumulatedFrameCount: 64,
                            maxAccumulatedFrameSize: 1 << 20),
                        RelayHandler(request: request, configuration: configuration))
                }
            })

        return channel.eventLoop.makeCompletedFuture {
            let pipeline = channel.pipeline.syncOperations
            try pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
            try pipeline.addHandler(HTTPRejectionHandler(configuration: configuration, log: log))
        }
    }

    static func hasRequiredHeaders(_ headers: HTTPHeaders) -> Bool {
        let subprotocols = headers[canonicalForm: "sec-websocket-protocol"].map(String.init)
        return subprotocols.contains(relaySubprotocol) && headers.first(name: "Origin") == relayOrigin
    }

    static func handshake(from request: HTTPRequestHead, upgraded: Bool) -> Handshake {
        let components = URLComponents(string: request.uri)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Handshake(
            path: components?.path ?? request.uri,
            query: query,
            origin: request.headers.first(name: "Origin"),
            subprotocols: request.headers[canonicalForm: "sec-websocket-protocol"].map(String.init),
            hasBearerToken: request.headers.first(name: "Authorization")?.hasPrefix("Bearer ") ?? false,
            upgraded: upgraded)
    }

    private enum MockServerError: Error {
        case missingLocalPort
    }
}

/// Registro de handshakes compartido entre event loop y test.
/// `@unchecked Sendable`: todo acceso a `storage` pasa por `lock`.
private final class HandshakeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MockIAPRelayServer.Handshake] = []

    var entries: [MockIAPRelayServer.Handshake] {
        lock.withLock { storage }
    }

    func append(_ entry: MockIAPRelayServer.Handshake) {
        lock.withLock { storage.append(entry) }
    }
}

// MARK: - Rechazo HTTP (403/404/400)

/// Responde a toda petición que no se convirtió en WebSocket:
/// modo `handshakeFailure` → 403/404; cabeceras inválidas o GET normal → 400.
private final class HTTPRejectionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let configuration: MockIAPRelayServer.Configuration
    private let log: HandshakeLog
    private var didRespond = false

    init(configuration: MockIAPRelayServer.Configuration, log: HandshakeLog) {
        self.configuration = configuration
        self.log = log
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !didRespond, case .head(let request) = unwrapInboundIn(data) else { return }
        didRespond = true
        log.append(MockIAPRelayServer.handshake(from: request, upgraded: false))

        let status = configuration.handshakeFailure?.status ?? .badRequest
        var head = HTTPResponseHead(version: request.version, status: status)
        head.headers.add(name: "Content-Length", value: "0")
        head.headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // `shouldUpgrade` → nil hace que NIO emita `unsupportedWebSocketTarget`
        // y luego reenvíe la petición: no cerrar aquí o el cliente recibe una
        // respuesta vacía en vez del 400/403/404.
        if let upgradeError = error as? NIOWebSocketUpgradeError,
           upgradeError == .unsupportedWebSocketTarget {
            return
        }
        context.close(promise: nil)
    }
}

// MARK: - Framing v4 lado servidor

private final class RelayHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let request: HTTPRequestHead
    private let configuration: MockIAPRelayServer.Configuration
    private var receivedBytes: UInt64 = 0
    private var sentClose = false
    /// Modo backend: conexión TCP hacia el destino (p. ej. MockSSHServer).
    private var backendChannel: (any Channel)?

    init(request: HTTPRequestHead, configuration: MockIAPRelayServer.Configuration) {
        self.request = request
        self.configuration = configuration
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let handshake = MockIAPRelayServer.handshake(from: request, upgraded: true)

        if handshake.path.hasPrefix("/v4/reconnect") {
            guard handshake.query["sid"] == configuration.sessionID else {
                sendClose(MockIAPRelayServer.RelayCloseCode.sidUnknown.rawValue, reason: "unknown sid", context: context)
                return
            }
            if let close = configuration.close, !close.afterSessionID {
                sendScheduledClose(close, context: context)
                return
            }
            writeBinary(RelayWire.reconnectSuccessAck(configuration.reconnectAck), context: context)
        } else {
            if let close = configuration.close, !close.afterSessionID {
                sendScheduledClose(close, context: context)
                return
            }
            if let backend = configuration.backend {
                // Como IAP: conecta al backend y solo entonces confirma el SID.
                connectBackend(backend, context: context)
                return
            }
            writeBinary(RelayWire.connectSuccessSid(configuration.sessionID), context: context)
        }

        if let close = configuration.close {
            sendScheduledClose(close, context: context)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary:
            handleMessage(Array(frame.unmaskedData.readableBytesView), context: context)
        case .ping:
            context.writeAndFlush(
                wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)),
                promise: nil)
        case .connectionClose:
            // Respuesta del cliente a nuestro close, o close iniciado por él.
            if sentClose {
                context.close(promise: nil)
            } else {
                sentClose = true
                let channel = context.channel
                context.writeAndFlush(
                    wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData))
                ).whenComplete { _ in channel.close(promise: nil) }
            }
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        backendChannel?.close(promise: nil)
        context.fireChannelInactive()
    }

    private func connectBackend(_ backend: MockIAPRelayServer.Backend, context: ChannelHandlerContext) {
        let wsChannel = context.channel
        let sessionID = configuration.sessionID
        // El handler no es Sendable: se accede solo desde su event loop.
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(BackendToRelayHandler(relay: wsChannel))
                }
            }
            .connect(host: backend.host, port: backend.port)
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    handler.value.backendChannel = channel
                    Self.send(RelayWire.connectSuccessSid(sessionID), on: wsChannel)
                case .failure:
                    // Destino inalcanzable: como IAP, FAILED_TO_CONNECT_TO_BACKEND.
                    Self.close(code: 4003, reason: "backend unreachable", on: wsChannel)
                }
            }
    }

    static func send(_ bytes: [UInt8], on channel: any Channel) {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: buffer), promise: nil)
    }

    static func close(code: UInt16, reason: String, on channel: any Channel) {
        var buffer = channel.allocator.buffer(capacity: 2 + reason.utf8.count)
        buffer.writeInteger(code)
        buffer.writeString(reason)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer))
            .whenComplete { _ in
                channel.eventLoop.scheduleTask(in: .seconds(2)) { channel.close(promise: nil) }
            }
    }

    private func handleMessage(_ message: [UInt8], context: ChannelHandlerContext) {
        guard message.count >= 2 else {
            sendClose(RelayHandler.invalidTag, reason: "truncated message", context: context)
            return
        }
        switch RelayWire.tag(message) {
        case RelayWire.Tag.data:
            guard message.count >= 6 else {
                sendClose(RelayHandler.invalidTag, reason: "truncated DATA", context: context)
                return
            }
            let length = Int(RelayWire.uint32(message, at: 2))
            guard length > 0, length <= RelayWire.maxArrayLength, message.count == 6 + length else {
                sendClose(RelayHandler.invalidTag, reason: "invalid DATA length", context: context)
                return
            }
            receivedBytes += UInt64(length)
            if let backendChannel {
                // Modo backend: entrega al destino y confirma lo recibido.
                var buffer = backendChannel.allocator.buffer(capacity: length)
                buffer.writeBytes(message[6...])
                backendChannel.writeAndFlush(buffer, promise: nil)
                writeBinary(RelayWire.ack(receivedBytes), context: context)
            } else {
                writeBinary(RelayWire.data(Array(message[6...])), context: context, flush: false)
                writeBinary(RelayWire.ack(receivedBytes), context: context)
            }
        case RelayWire.Tag.ack:
            // El cliente confirma lo que le enviamos; el mock no reenvía nada.
            break
        default:
            // Como el servidor real con tags desconocidos: INVALID_TAG.
            sendClose(RelayHandler.invalidTag, reason: "invalid tag", context: context)
        }
    }

    private func sendScheduledClose(_ close: MockIAPRelayServer.CloseBehavior, context: ChannelHandlerContext) {
        if close.sendLongClose {
            writeBinary(
                RelayWire.longClose(code: UInt32(close.code.rawValue), reason: close.reason),
                context: context, flush: false)
        }
        sendClose(close.code.rawValue, reason: close.reason, context: context)
    }

    private func sendClose(_ code: UInt16, reason: String, context: ChannelHandlerContext) {
        guard !sentClose else { return }
        sentClose = true
        var buffer = context.channel.allocator.buffer(capacity: 2 + reason.utf8.count)
        buffer.writeInteger(code)  // big-endian (RFC 6455 §5.5.1)
        buffer.writeString(reason)
        let channel = context.channel
        context.writeAndFlush(
            wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer))
        ).whenComplete { _ in
            // Si el cliente no contesta al close, no dejar el socket colgado.
            channel.eventLoop.scheduleTask(in: .seconds(2)) { channel.close(promise: nil) }
        }
    }

    private func writeBinary(_ bytes: [UInt8], context: ChannelHandlerContext, flush: Bool = true) {
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        let frame = wrapOutboundOut(WebSocketFrame(fin: true, opcode: .binary, data: buffer))
        if flush {
            context.writeAndFlush(frame, promise: nil)
        } else {
            context.write(frame, promise: nil)
        }
    }

    /// `INVALID_TAG` / mensaje malformado (close code de protocolo).
    static let invalidTag: UInt16 = 4008
}

// MARK: - Encoding wire v4

/// Encode/decode mínimo del framing v4 (big-endian) para el mock.
/// TODO(CBU-26): sustituir por `SshRelayFormat` cuando esta rama incluya
/// CBU-26 (ya en main); los vectores deben coincidir byte a byte.
private enum RelayWire {
    static let maxArrayLength = 16 * 1024

    enum Tag {
        static let connectSuccessSid: UInt16 = 1
        static let reconnectSuccessAck: UInt16 = 2
        static let data: UInt16 = 4
        static let ack: UInt16 = 7
        static let longClose: UInt16 = 10
    }

    static func connectSuccessSid(_ sid: String) -> [UInt8] {
        let bytes = Array(sid.utf8)
        return uint16(Tag.connectSuccessSid) + uint32(UInt32(bytes.count)) + bytes
    }

    static func reconnectSuccessAck(_ ack: UInt64) -> [UInt8] {
        uint16(Tag.reconnectSuccessAck) + uint64(ack)
    }

    static func data(_ payload: [UInt8]) -> [UInt8] {
        uint16(Tag.data) + uint32(UInt32(payload.count)) + payload
    }

    static func ack(_ ack: UInt64) -> [UInt8] {
        uint16(Tag.ack) + uint64(ack)
    }

    static func longClose(code: UInt32, reason: String) -> [UInt8] {
        let bytes = Array(reason.utf8.prefix(maxArrayLength))
        return uint16(Tag.longClose) + uint32(code) + uint32(UInt32(bytes.count)) + bytes
    }

    static func tag(_ message: [UInt8]) -> UInt16 {
        UInt16(message[0]) << 8 | UInt16(message[1])
    }

    static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    static func uint64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[offset + $1]) }
    }

    private static func uint16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    private static func uint32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * (3 - $0))) }
    }

    private static func uint64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * (7 - $0))) }
    }
}

/// Modo backend: lo que envía el destino sale al cliente como DATA (≤ 16 KiB);
/// si el destino cierra, el relay cierra con NORMAL (1000).
private final class BackendToRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let relay: any Channel

    init(relay: any Channel) {
        self.relay = relay
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        while buffer.readableBytes > 0 {
            let size = min(buffer.readableBytes, RelayWire.maxArrayLength)
            let chunk = Array(buffer.readSlice(length: size)!.readableBytesView)
            RelayHandler.send(RelayWire.data(chunk), on: relay)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        RelayHandler.close(code: 1000, reason: "backend closed", on: relay)
        context.fireChannelInactive()
    }
}
