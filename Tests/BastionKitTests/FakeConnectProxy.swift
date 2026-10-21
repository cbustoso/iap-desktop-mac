// GH-95: proxy HTTP `CONNECT` mínimo para tests (T-AZ-11). Registra el
// destino pedido y, en modo `.tunnel`, encamina el túnel a un puerto local
// (el `FakeBastionServer` con TLS) sea cual sea el host pedido.
import Foundation
import NIOCore
import NIOPosix

final class FakeConnectProxy: Sendable {
    enum Mode: Sendable {
        /// `200 Connection established` y bytes en crudo hacia `127.0.0.1:{port}`.
        case tunnel(toPort: Int)
        /// Responde con este status y cierra (p. ej. 403 política, 407 autenticación).
        case deny(status: Int)
    }

    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let log: ConnectLog

    /// Líneas `CONNECT host:port HTTP/1.1` recibidas, en orden.
    var connectRequests: [String] { log.value }

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: any Channel, log: ConnectLog) {
        self.port = port
        self.group = group
        self.channel = channel
        self.log = log
    }

    static func start(_ mode: Mode) async throws -> FakeConnectProxy {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let log = ConnectLog()
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ConnectHandler(mode: mode, log: log))
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            guard let port = channel.localAddress?.port else { throw ProxyError.noPort }
            return FakeConnectProxy(port: port, group: group, channel: channel, log: log)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func shutdown() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }

    private enum ProxyError: Error { case noPort }
}

/// `@unchecked Sendable`: acceso bajo `lock`.
private final class ConnectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var value: [String] { lock.withLock { lines } }
    func append(_ line: String) { lock.withLock { lines.append(line) } }
}

/// Lee la cabecera `CONNECT …\r\n\r\n` y después pega cliente ↔ destino.
private final class ConnectHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let mode: FakeConnectProxy.Mode
    private let log: ConnectLog
    private var header = ByteBuffer()
    private var upstream: (any Channel)?
    private var pending: [ByteBuffer] = []
    private var connecting = false

    init(mode: FakeConnectProxy.Mode, log: ConnectLog) {
        self.mode = mode
        self.log = log
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let upstream {
            upstream.writeAndFlush(buffer, promise: nil)
            return
        }
        if connecting {
            pending.append(buffer)
            return
        }
        header.writeBuffer(&buffer)
        let text = String(buffer: header)
        guard let end = text.range(of: "\r\n\r\n") else { return }
        let firstLine = String(text[..<end.lowerBound].split(separator: "\r\n").first ?? "")
        log.append(firstLine)
        let rest = header.getSlice(at: text.utf8.distance(from: text.startIndex, to: end.upperBound),
                                   length: text.utf8.distance(from: end.upperBound, to: text.endIndex))
        switch mode {
        case .deny(let status):
            let response = "HTTP/1.1 \(status) Denied\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: response)))
                .whenComplete { _ in channel.close(promise: nil) }
        case .tunnel(let port):
            connecting = true
            if let rest, rest.readableBytes > 0 { pending.append(rest) }
            let client = context.channel
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
            ClientBootstrap(group: context.eventLoop)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(PipeHandler(peer: client))
                    }
                }
                .connect(host: "127.0.0.1", port: port)
                .whenComplete { result in
                    switch result {
                    case .success(let channel):
                        let this = handler.value
                        this.upstream = channel
                        this.connecting = false
                        client.writeAndFlush(
                            client.allocator.buffer(string: "HTTP/1.1 200 Connection established\r\n\r\n"), promise: nil)
                        for buffer in this.pending { channel.write(buffer, promise: nil) }
                        this.pending.removeAll()
                        channel.flush()
                    case .failure:
                        client.close(promise: nil)
                    }
                }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

/// Destino → cliente.
private final class PipeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let peer: any Channel

    init(peer: any Channel) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
