import AuthKit
import Foundation
import NIOCore
import NIOPosix
import NIOWebSocket
import WebSocketKit

/// Proxy HTTP para `wss://` (túnel CONNECT). Resuelto vía `CFNetworkCopyProxiesForURL` (M4).
public struct ProxyConfig: Sendable, Equatable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// Canal WebSocket establecido con el relay: mensajes binarios completos
/// (un mensaje relay v4 por frame) en ambos sentidos.
public protocol RelayChannel: Sendable {
    func send(_ data: Data) async throws
    /// Mensajes recibidos; termina cuando el WebSocket se cierra.
    func incoming() -> AsyncStream<Data>
    /// Close code WebSocket recibido (4033, 4047…), disponible tras el cierre.
    func closeCode() async -> Int?
    func close() async
}

/// Abre canales hacia el relay; inyectable para tests (canal en memoria).
public protocol RelayChannelOpening: Sendable {
    func open(_ url: URL, accessToken: String) async throws -> any RelayChannel
}

/// Transporte WebSocket hacia `tunnel.cloudproxy.app`.
///
/// Resultado del spike T-TUN-1: SwiftNIO + WebSocketKit (ver
/// `specs/tunnel/transport-decision.md`). Cubre headers
/// (`Authorization`/`Origin`/`User-Agent`/subprotocolo), proxy CONNECT,
/// `wss` vía NIOSSL, ping de keepalive, timeout de handshake y mapeo de
/// errores HTTP del handshake.
public struct NIOWebSocketTransport: RelayChannelOpening {
    public var userAgent: String
    public var maxFrameSize: Int
    public var proxy: ProxyConfig?
    public var connectTimeout: Duration
    /// GH-68: certificado de dispositivo para mTLS (`nil` = TLS normal, como antes).
    public var clientIdentity: DeviceIdentity?

    public init(
        userAgent: String = "iap-desktop-mac/0.1",
        maxFrameSize: Int = 1 << 20,
        proxy: ProxyConfig? = nil,
        connectTimeout: Duration = .seconds(30),
        clientIdentity: DeviceIdentity? = nil
    ) {
        self.userAgent = userAgent
        self.maxFrameSize = maxFrameSize
        self.proxy = proxy
        self.connectTimeout = connectTimeout
        self.clientIdentity = clientIdentity
    }

    public func open(_ url: URL, accessToken: String) async throws -> any RelayChannel {
        try await connect(to: url, accessToken: accessToken, proxy: proxy)
    }

    public func connect(
        to url: URL, accessToken: String, proxy: ProxyConfig? = nil
    ) async throws -> some RelayChannel {
        guard url.scheme == "wss" || url.scheme == "ws" else { throw TunnelError.invalidURL }
        let configuration = try webSocketConfiguration()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let closeCode = CloseCodeBox()
        let once = ResumeOnce()
        do {
            let socket: WebSocket = try await withCheckedThrowingContinuation { resume in
                // WebSocketKit no completa `connect` si el servidor cierra sin
                // responder: sin este timeout la llamada colgaría para siempre.
                let timeout = group.next().scheduleTask(in: .nanoseconds(Int64(connectTimeout.totalNanoseconds))) {
                    if once.claim() { resume.resume(throwing: TunnelError.timeout) }
                }
                let future = WebSocket.connect(
                    to: url.absoluteString,
                    headers: [
                        "Authorization": "Bearer \(accessToken)",
                        "Origin": IapEndpoint.origin,
                        "User-Agent": self.userAgent,
                        "Sec-WebSocket-Protocol": IapEndpoint.subprotocol,
                    ],
                    proxy: proxy?.host,
                    proxyPort: proxy?.port,
                    configuration: configuration,
                    on: group
                ) { ws in
                    ws.onBinary { _, buffer in
                        continuation.yield(Data(buffer.readableBytesView))
                    }
                    ws.onClose.whenComplete { _ in
                        // Antes de terminar `incoming`: quien lea el fin ya ve el código.
                        closeCode.set(ws.closeCode.map { Int(Self.code(of: $0)) })
                        continuation.finish()
                    }
                    timeout.cancel()
                    if once.claim() { resume.resume(returning: ws) } else { _ = ws.close() }
                }
                future.whenFailure { error in
                    timeout.cancel()
                    if once.claim() { resume.resume(throwing: Self.mapHandshakeError(error, viaProxy: proxy != nil)) }
                }
            }
            let channel = NIORelayChannel(socket: socket, group: group, stream: stream, closeCode: closeCode)
            await channel.start()
            return channel
        } catch {
            continuation.finish()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// 403 → acceso denegado (o proxy que bloquea WS), 404 → backend
    /// inexistente, 407 → proxy exige autenticación. El token no aparece.
    static func mapHandshakeError(_ error: any Error, viaProxy: Bool) -> TunnelError {
        if let error = error as? TunnelError { return error }
        if case WebSocketClient.Error.invalidResponseStatus(let head) = error {
            switch head.status.code {
            case 403: return .connectionDenied
            case 404: return .backendNotFound
            case 407: return .proxyBlocked
            default: return .handshakeFailed("HTTP \(head.status.code)")
            }
        }
        return viaProxy ? .proxyBlocked : .handshakeFailed(String(describing: type(of: error)))
    }

    static func code(of code: WebSocketErrorCode) -> UInt16 {
        switch code {
        case .normalClosure: return 1000
        case .goingAway: return 1001
        case .protocolError: return 1002
        case .unacceptableData: return 1003
        case .dataInconsistentWithMessage: return 1007
        case .policyViolation: return 1008
        case .messageTooLarge: return 1009
        case .missingExtension: return 1010
        case .unexpectedServerError: return 1011
        case .unknown(let value): return value
        }
    }
}

/// Canal sobre `WebSocketKit.WebSocket`: ping de keepalive 60 s, cierre limpio.
private actor NIORelayChannel: RelayChannel {
    private let socket: WebSocket
    private let group: MultiThreadedEventLoopGroup
    private let stream: AsyncStream<Data>
    private let code: CloseCodeBox
    private var keepalive: Task<Void, Never>?
    private var closed = false

    init(socket: WebSocket, group: MultiThreadedEventLoopGroup, stream: AsyncStream<Data>, closeCode: CloseCodeBox) {
        self.socket = socket
        self.group = group
        self.stream = stream
        self.code = closeCode
    }

    func start() {
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(IapEndpoint.keepAliveSeconds))
                guard !Task.isCancelled else { break }
                await self?.ping()
            }
        }
    }

    private func ping() {
        socket.sendPing(promise: nil)
    }

    func send(_ data: Data) async throws {
        guard !socket.isClosed else { throw TunnelError.relayClosed(code: code.value ?? 1006) }
        // Con promesa: un fallo de escritura llega a quien llama (antes se perdía).
        let written = socket.eventLoop.makePromise(of: Void.self)
        socket.send(Array(data), promise: written)
        try await written.futureResult.get()
    }

    nonisolated func incoming() -> AsyncStream<Data> { stream }

    func closeCode() async -> Int? { code.value }

    func close() async {
        guard !closed else { return }
        closed = true
        keepalive?.cancel()
        keepalive = nil
        _ = try? await socket.close().get()
        try? await group.shutdownGracefully()
    }
}

/// `@unchecked Sendable`: acceso bajo `lock`.
final class CloseCodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?

    var value: Int? { lock.withLock { stored } }

    func set(_ code: Int?) { lock.withLock { stored = code } }
}

/// Garantiza un único `resume` entre timeout, éxito y fallo.
final class ResumeOnce: @unchecked Sendable {
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
    var totalNanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
