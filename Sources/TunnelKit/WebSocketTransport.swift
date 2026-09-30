import Foundation
import NIOCore
import NIOPosix
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

/// Canal WebSocket establecido: envío binario + stream de recepción.
public protocol RelayChannel: Sendable {
    func send(_ data: Data) async throws
    func incoming() -> AsyncStream<Data>
    func close() async
}

/// Transporte WebSocket hacia `tunnel.cloudproxy.app`.
///
/// Resultado del spike T-TUN-1: SwiftNIO + WebSocketKit (ver
/// `specs/tunnel/transport-decision.md`). Cubre headers
/// (`Authorization`/`Origin`/`User-Agent`/subprotocolo), proxy CONNECT,
/// `wss` vía NIOSSL y ping de keepalive.
public struct NIOWebSocketTransport: Sendable {
    public var userAgent: String
    public var maxFrameSize: Int

    public init(userAgent: String = "iap-desktop-mac/0.1", maxFrameSize: Int = 1 << 20) {
        self.userAgent = userAgent
        self.maxFrameSize = maxFrameSize
    }

    public func connect(
        to url: URL, accessToken: String, proxy: ProxyConfig? = nil
    ) async throws -> some RelayChannel {
        guard url.scheme == "wss" || url.scheme == "ws" else { throw TunnelError.invalidURL }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let socket: WebSocket = try await withCheckedThrowingContinuation { resume in
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
                configuration: .init(maxFrameSize: self.maxFrameSize),
                on: group
            ) { ws in
                ws.onBinary { _, buffer in
                    continuation.yield(Data(buffer.readableBytesView))
                }
                ws.onClose.whenComplete { _ in continuation.finish() }
                resume.resume(returning: ws)
            }
            future.whenFailure { resume.resume(throwing: self.mapHandshakeError($0)) }
        }
        let channel = NIORelayChannel(socket: socket, group: group, stream: stream)
        await channel.start()
        return channel
    }

    private func mapHandshakeError(_ error: Error) -> TunnelError {
        // T-TUN-4 afina el mapeo 403/404 contra el mock (T-TUN-6).
        .handshakeFailed(String(describing: error))
    }
}

/// Canal sobre `WebSocketKit.WebSocket`: ping de keepalive 60 s, cierre limpio.
private actor NIORelayChannel: RelayChannel {
    private let socket: WebSocket
    private let group: MultiThreadedEventLoopGroup
    private let stream: AsyncStream<Data>
    private var keepalive: Task<Void, Never>?

    init(socket: WebSocket, group: MultiThreadedEventLoopGroup, stream: AsyncStream<Data>) {
        self.socket = socket
        self.group = group
        self.stream = stream
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
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            socket.send(Array(data), promise: nil)
            // `send` sin promise no reporta fallo; el error llega vía onClose/stream.
            resume.resume()
        }
    }

    nonisolated func incoming() -> AsyncStream<Data> { stream }

    func close() async {        keepalive?.cancel()
        keepalive = nil
        _ = try? await socket.close().get()
        try? await group.shutdownGracefully()
    }
}
