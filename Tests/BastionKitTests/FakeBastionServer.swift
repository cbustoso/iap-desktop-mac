// Servidor `/webtunnelv2` falso para BastionKit (research §9.5 (2)), portado
// del spike `Spikes/BastionSpike`. Solo tests: `ws://127.0.0.1:{efímero}`,
// sin TLS ni credenciales.
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

final class FakeBastionServer: Sendable {
    enum Behavior: Sendable, Equatable {
        /// Eco de cada frame binario.
        case echo
        /// Reenvía los bytes a un TCP local (p. ej. `MockSSHServer`).
        case forward(port: Int)
        /// Responde al primer frame con un frame de texto.
        case textOnFirstFrame
        /// Responde al primer frame con Close `code`.
        case closeOnFirstFrame(code: UInt16)
        /// Corta el TCP al recibir el primer frame (sin Close).
        case dropOnFirstFrame
        /// Rechaza el upgrade con este status HTTP.
        case reject(status: Int)
    }

    struct Handshake: Sendable, Equatable {
        var path: String
        var query: String?
        var origin: String?
        var hasSubprotocol: Bool
        var hasAuthorization: Bool
    }

    struct Observed: Sendable, Equatable {
        var handshakes: [Handshake] = []
        /// Tamaño de cada frame binario recibido del cliente.
        var frameSizes: [Int] = []
        /// Códigos de los Close recibidos del cliente.
        var clientCloseCodes: [UInt16] = []
    }

    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let recorder: Recorder

    var observed: Observed { recorder.value }

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: any Channel, recorder: Recorder) {
        self.port = port
        self.group = group
        self.channel = channel
        self.recorder = recorder
    }

    static func start(_ behavior: Behavior = .echo) async throws -> FakeBastionServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = Recorder()
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .childChannelInitializer { channel in
                    configure(channel: channel, behavior: behavior, recorder: recorder)
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            guard let port = channel.localAddress?.port else { throw FakeServerError.noPort }
            return FakeBastionServer(port: port, group: group, channel: channel, recorder: recorder)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func shutdown() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }

    private enum FakeServerError: Error { case noPort }

    private static func configure(
        channel: any Channel, behavior: Behavior, recorder: Recorder
    ) -> EventLoopFuture<Void> {
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 24,
            shouldUpgrade: { channel, head in
                recorder.update { $0.handshakes.append(handshake(from: head)) }
                if case .reject = behavior { return channel.eventLoop.makeSucceededFuture(nil) }
                // Sin subprotocolo: no se devuelve Sec-WebSocket-Protocol.
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    let rejection = try pipeline.handler(type: RejectionHandler.self)
                    pipeline.removeHandler(rejection, promise: nil)
                    try pipeline.addHandlers(
                        NIOWebSocketFrameAggregator(
                            minNonFinalFragmentSize: 1, maxAccumulatedFrameCount: 64,
                            maxAccumulatedFrameSize: 1 << 24),
                        TunnelHandler(behavior: behavior, recorder: recorder))
                }
            })
        return channel.eventLoop.makeCompletedFuture {
            let pipeline = channel.pipeline.syncOperations
            try pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
            var status = HTTPResponseStatus.badRequest
            if case .reject(let code) = behavior { status = HTTPResponseStatus(statusCode: code) }
            try pipeline.addHandler(RejectionHandler(status: status))
        }
    }

    private static func handshake(from head: HTTPRequestHead) -> Handshake {
        let parts = head.uri.split(separator: "?", maxSplits: 1).map(String.init)
        return Handshake(
            path: parts.first ?? head.uri,
            query: parts.count > 1 ? parts[1] : nil,
            origin: head.headers.first(name: "Origin"),
            hasSubprotocol: head.headers.contains(name: "Sec-WebSocket-Protocol"),
            hasAuthorization: head.headers.contains(name: "Authorization"))
    }
}

/// `@unchecked Sendable`: todo acceso pasa por `lock`.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = FakeBastionServer.Observed()

    var value: FakeBastionServer.Observed { lock.withLock { storage } }

    func update(_ body: (inout FakeBastionServer.Observed) -> Void) {
        lock.withLock { body(&storage) }
    }
}

/// Responde a lo que no se convirtió en WebSocket (modo `.reject`).
private final class RejectionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let status: HTTPResponseStatus
    private var responded = false

    init(status: HTTPResponseStatus) { self.status = status }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded, case .head(let request) = unwrapInboundIn(data) else { return }
        responded = true
        var head = HTTPResponseHead(version: request.version, status: status)
        head.headers.add(name: "Content-Length", value: "0")
        head.headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // Tras `shouldUpgrade` → nil, NIO reenvía la petición: no cerrar aquí.
        if let upgradeError = error as? NIOWebSocketUpgradeError, upgradeError == .unsupportedWebSocketTarget {
            return
        }
        context.close(promise: nil)
    }
}

private final class TunnelHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let behavior: FakeBastionServer.Behavior
    private let recorder: Recorder
    private var sentClose = false
    private var backend: (any Channel)?
    private var pendingToBackend: [ByteBuffer] = []

    init(behavior: FakeBastionServer.Behavior, recorder: Recorder) {
        self.behavior = behavior
        self.recorder = recorder
    }

    func handlerAdded(context: ChannelHandlerContext) {
        guard case .forward(let port) = behavior else { return }
        let wsChannel = context.channel
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(BackendHandler(tunnel: wsChannel))
                }
            }
            .connect(host: "127.0.0.1", port: port)
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    handler.value.backend = channel
                    for buffer in handler.value.pendingToBackend { channel.write(buffer, promise: nil) }
                    handler.value.pendingToBackend.removeAll()
                    channel.flush()
                case .failure:
                    wsChannel.close(promise: nil)
                }
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary:
            let payload = frame.unmaskedData
            let isFirst = recorder.value.frameSizes.isEmpty
            recorder.update { $0.frameSizes.append(payload.readableBytes) }
            handleBinary(payload, isFirst: isFirst, context: context)
        case .connectionClose:
            var data = frame.unmaskedData
            if let code = data.readInteger(as: UInt16.self) {
                recorder.update { $0.clientCloseCodes.append(code) }
            }
            if sentClose {
                context.close(promise: nil)
            } else {
                sentClose = true
                let channel = context.channel
                context.writeAndFlush(
                    wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData))
                ).whenComplete { _ in channel.close(promise: nil) }
            }
        case .ping:
            context.writeAndFlush(
                wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        default:
            break
        }
    }

    private func handleBinary(_ payload: ByteBuffer, isFirst: Bool, context: ChannelHandlerContext) {
        switch behavior {
        case .echo, .reject:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .binary, data: payload)), promise: nil)
        case .forward:
            if let backend {
                backend.writeAndFlush(payload, promise: nil)
            } else {
                pendingToBackend.append(payload)
            }
        case .textOnFirstFrame:
            guard isFirst else { return }
            var text = context.channel.allocator.buffer(capacity: 16)
            text.writeString("{\"error\":\"nope\"}")
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: text)), promise: nil)
        case .closeOnFirstFrame(let code):
            guard isFirst, !sentClose else { return }
            sentClose = true
            var buffer = context.channel.allocator.buffer(capacity: 2)
            buffer.writeInteger(code)
            context.writeAndFlush(
                wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)), promise: nil)
        case .dropOnFirstFrame:
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        backend?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

/// Backend TCP → frames binarios hacia el cliente.
private final class BackendHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let tunnel: any Channel

    init(tunnel: any Channel) { self.tunnel = tunnel }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        tunnel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: buffer), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        tunnel.close(promise: nil)
        context.fireChannelInactive()
    }
}
