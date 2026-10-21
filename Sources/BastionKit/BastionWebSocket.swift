import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import TunnelKit
import WebSocketKit

/// Upgrade del túnel tal como lo genera el CLI (research §3.3 (3)):
/// `wss://{dnsName}/webtunnelv2/{websocketToken}?X-Node-Id={nodeId}` con
/// `Origin: https://{dnsName}` y nada más: **sin** subprotocolo, **sin**
/// `Authorization` y sin mensaje inicial.
public struct BastionWebSocketRequest: Sendable, Equatable, CustomStringConvertible {
    public let host: String
    /// Sin percent-encoding: el CLI interpola el token tal cual (`tunnel.py` L136)
    /// y `URL.path` decodificaría escapes `%`.
    public let path: String
    public let query: String
    public let origin: String

    public static func tunnel(dnsName: String, session: BastionSessionClient.Session) -> BastionWebSocketRequest {
        BastionWebSocketRequest(
            host: dnsName,
            path: "/webtunnelv2/\(session.websocketToken)",
            query: "X-Node-Id=\(session.nodeID)",
            origin: "https://\(dnsName)")
    }

    /// Nunca la URL completa (REQ-AZ-8): el token va como huella.
    public var description: String {
        let token = path.split(separator: "/").last.map(String.init) ?? ""
        return "wss://\(host)/webtunnelv2/\(BastionRedaction.fingerprint(token))?\(query)"
    }
}

public enum BastionInboundMessage: Sendable, Equatable {
    case binary(Data)
    /// Frame de texto: el contenido no se conserva (no forma parte del protocolo).
    case text
}

/// WebSocket ya abierto hacia el Bastion (falso en tests de unidad).
public protocol BastionSocket: Sendable {
    /// Un frame binario por llamada.
    func send(_ data: Data) async throws
    /// Mensajes recibidos; termina cuando el WebSocket se cierra.
    func inbound() -> AsyncStream<BastionInboundMessage>
    /// Código del Close recibido; `nil` si la conexión cayó sin Close.
    func closeCode() async -> Int?
    /// Close 1000.
    func close() async
}

public protocol BastionSocketOpening: Sendable {
    func open(_ request: BastionWebSocketRequest) async throws -> any BastionSocket
}

/// Transporte SwiftNIO + WebSocketKit, mismo patrón que
/// `TunnelKit.NIOWebSocketTransport` (timeout de handshake propio, proxy
/// CONNECT, mapeo de errores HTTP) pero con el handshake del Bastion.
public struct NIOBastionWebSocketTransport: BastionSocketOpening {
    /// Destino de la conexión TCP distinto del `dnsName` (solo tests: `ws://127.0.0.1:{puerto}`).
    /// `Origin` y path siguen siendo los del Bastion.
    public struct Endpoint: Sendable, Equatable {
        public var scheme: String
        public var host: String
        public var port: Int

        public init(scheme: String, host: String, port: Int) {
            self.scheme = scheme
            self.host = host
            self.port = port
        }
    }

    /// GH-95: proxy HTTP para el `CONNECT {dnsName}:443` (REQ-AZ-9). Ver
    /// `BastionNetworkConfiguration.resolve` para tomarlo del sistema.
    public var proxy: ProxyConfig?
    public var connectTimeout: Duration
    /// RDP manda ráfagas grandes: el límite por defecto (16 KiB) cerraría el WS.
    public var maxFrameSize: Int
    public var endpointOverride: Endpoint?
    /// GH-95: ping WebSocket periódico; sin pong antes del siguiente ping, el
    /// WebSocket se da por muerto (Close 1006 → `.connectionLost(1006)`), así
    /// un corte a medias (NAT, Wi‑Fi, suspensión) no deja la conexión colgada
    /// en silencio. `nil` lo desactiva.
    public var pingInterval: Duration?
    /// Solo tests: TLS que confía en la CA del servidor falso.
    var tlsConfiguration: TLSConfiguration?

    public init(
        proxy: ProxyConfig? = nil,
        connectTimeout: Duration = .seconds(30),
        maxFrameSize: Int = 1 << 24,
        endpointOverride: Endpoint? = nil,
        pingInterval: Duration? = .seconds(30)
    ) {
        self.proxy = proxy
        self.connectTimeout = connectTimeout
        self.maxFrameSize = maxFrameSize
        self.endpointOverride = endpointOverride
        self.pingInterval = pingInterval
    }

    public func open(_ request: BastionWebSocketRequest) async throws -> any BastionSocket {
        let headers = HTTPHeaders([("Origin", request.origin)])
        let scheme = endpointOverride?.scheme ?? "wss"
        let host = endpointOverride?.host ?? request.host
        let port = endpointOverride?.port ?? 443
        let proxy = self.proxy
        if let proxy, scheme == "wss" {
            // WebSocketKit cierra el canal sin fallar `connect` si el proxy
            // rechaza el CONNECT (se vería como timeout): se sondea antes.
            try await BastionProxyProbe.check(proxy, host: host, port: port, timeout: connectTimeout)
        }
        let configuration = WebSocketClient.Configuration(tlsConfiguration: tlsConfiguration, maxFrameSize: maxFrameSize)
        let ping = pingInterval.map { TimeAmount.nanoseconds($0.nanoseconds) }
        let group = MultiThreadedEventLoopGroup.singleton
        let (stream, continuation) = AsyncStream<BastionInboundMessage>.makeStream()
        let closeCode = LockedBox<Int?>(nil)
        let once = OnceFlag()
        let timeoutNanos = connectTimeout.nanoseconds
        do {
            let socket: WebSocket = try await withCheckedThrowingContinuation { resume in
                // WebSocketKit no completa `connect` si el servidor calla.
                let timeout = group.next().scheduleTask(in: .nanoseconds(timeoutNanos)) {
                    if once.claim() { resume.resume(throwing: BastionTunnelError.timeout) }
                }
                WebSocket.connect(
                    scheme: scheme,
                    host: host,
                    port: port,
                    path: request.path,
                    query: request.query,
                    headers: headers,
                    proxy: proxy?.host,
                    proxyPort: proxy?.port,
                    configuration: configuration,
                    on: group
                ) { ws in
                    ws.onBinary { _, buffer in
                        continuation.yield(.binary(Data(buffer.readableBytesView)))
                    }
                    ws.onText { _, _ in
                        continuation.yield(.text)
                    }
                    ws.onClose.whenComplete { _ in
                        // Antes de terminar `inbound`: quien lea el fin ya ve el código.
                        closeCode.set(ws.closeCode.map { Int(UInt16(webSocketErrorCode: $0)) })
                        continuation.finish()
                    }
                    timeout.cancel()
                    if once.claim() {
                        ws.pingInterval = ping
                        resume.resume(returning: ws)
                    } else {
                        _ = ws.close()
                    }
                }.whenFailure { error in
                    timeout.cancel()
                    if once.claim() { resume.resume(throwing: Self.mapHandshakeError(error, viaProxy: proxy != nil)) }
                }
            }
            return NIOBastionSocket(socket: socket, stream: stream, code: closeCode)
        } catch {
            continuation.finish()
            throw error
        }
    }

    /// 401/403 → sin permiso (o websocketToken caducado), 404 → sesión
    /// inexistente, 407 → proxy con autenticación. Nunca incluye la URL.
    static func mapHandshakeError(_ error: any Error, viaProxy: Bool) -> BastionTunnelError {
        if let error = error as? BastionTunnelError { return error }
        if case WebSocketClient.Error.invalidResponseStatus(let head) = error {
            switch head.status.code {
            case 401, 403: return .unauthorized(message: nil)
            case 404: return .targetNotFound
            case 407: return .proxyBlocked
            default: return .protocolChanged(status: Int(head.status.code))
            }
        }
        return viaProxy ? .proxyBlocked : .network(String(describing: type(of: error)))
    }
}

/// `WebSocketKit.WebSocket` como `BastionSocket`.
final class NIOBastionSocket: BastionSocket {
    private let socket: WebSocket
    private let stream: AsyncStream<BastionInboundMessage>
    private let code: LockedBox<Int?>

    init(socket: WebSocket, stream: AsyncStream<BastionInboundMessage>, code: LockedBox<Int?>) {
        self.socket = socket
        self.stream = stream
        self.code = code
    }

    func send(_ data: Data) async throws {
        guard !socket.isClosed else { throw BastionTunnelError.connectionLost(code: code.value) }
        // Con promesa: un fallo de escritura llega a quien llama.
        let written = socket.eventLoop.makePromise(of: Void.self)
        socket.send(raw: data, opcode: .binary, fin: true, promise: written)
        try await written.futureResult.get()
    }

    func inbound() -> AsyncStream<BastionInboundMessage> { stream }

    func closeCode() async -> Int? { code.value }

    func close() async {
        guard !socket.isClosed else { return }
        // Explícito: WebSocketKit usa `goingAway` (1001) por defecto.
        try? await socket.close(code: .normalClosure).get()
    }
}

// MARK: - Sondeo del proxy

/// GH-95: `CONNECT host:port` de prueba contra el proxy para convertir un
/// rechazo (403, 407, cierre) en `.proxyBlocked` inmediato. Un éxito se
/// recuerda `ttl` por proxy y destino: no se repite en cada túnel.
enum BastionProxyProbe {
    static let ttl: Duration = .seconds(60)
    private static let recent = LockedBox<[String: ContinuousClock.Instant]>([:])

    static func check(_ proxy: ProxyConfig, host: String, port: Int, timeout: Duration) async throws {
        let key = "\(proxy.host):\(proxy.port)>\(host):\(port)"
        let now = ContinuousClock.now
        if let last = recent.value[key], now - last < ttl { return }
        let status: Int?
        do {
            status = try await connectStatus(proxy, host: host, port: port, timeout: timeout)
        } catch {
            throw BastionTunnelError.proxyBlocked
        }
        guard let status, (200...299).contains(status) else { throw BastionTunnelError.proxyBlocked }
        recent.withValue { $0[key] = now }
    }

    /// Status de la respuesta al `CONNECT`; `nil` si el proxy cierra sin contestar.
    private static func connectStatus(_ proxy: ProxyConfig, host: String, port: Int, timeout: Duration) async throws -> Int? {
        let group = MultiThreadedEventLoopGroup.singleton
        let promise = group.next().makePromise(of: Int?.self)
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.nanoseconds(timeout.nanoseconds))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(StatusLineHandler(promise: promise))
                }
            }
            .connect(host: proxy.host, port: proxy.port)
            .get()
        let deadline = channel.eventLoop.scheduleTask(in: .nanoseconds(timeout.nanoseconds)) {
            promise.fail(BastionTunnelError.timeout)
        }
        let request = "CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n\r\n"
        channel.writeAndFlush(channel.allocator.buffer(string: request), promise: nil)
        defer {
            deadline.cancel()
            channel.close(promise: nil)
        }
        return try await promise.futureResult.get()
    }

    /// Lee hasta la primera línea (`HTTP/1.1 200 …`) y resuelve con su status.
    private final class StatusLineHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        private let promise: EventLoopPromise<Int?>
        private var buffer = ByteBuffer()
        private var done = false

        init(promise: EventLoopPromise<Int?>) { self.promise = promise }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var chunk = unwrapInboundIn(data)
            buffer.writeBuffer(&chunk)
            let text = String(buffer: buffer)
            guard !done, let end = text.range(of: "\r\n") else { return }
            done = true
            let parts = text[..<end.lowerBound].split(separator: " ")
            promise.succeed(parts.count > 1 ? Int(parts[1]) : nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            if !done { done = true; promise.succeed(nil) }
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            if !done { done = true; promise.fail(error) }
            context.close(promise: nil)
        }
    }
}

// MARK: - Utilidades

/// Valor bajo `lock`. `@unchecked Sendable`: todo acceso pasa por `lock`.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func set(_ value: Value) { lock.withLock { stored = value } }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&stored) }
    }
}

/// Garantiza un único `resume` entre timeout, éxito y fallo.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            guard !done else { return false }
            done = true
            return true
        }
    }
}

extension Duration {
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
