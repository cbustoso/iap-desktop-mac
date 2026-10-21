import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing
@testable import BastionSpikeCore

/// Servidor `/webtunnelv2` falso (ws:// en loopback): registra el upgrade y
/// hace eco de los frames binarios. Sin credenciales.
final class FakeBastionServer: @unchecked Sendable {
    private let lock = NSLock()
    private var head: HTTPRequestHead?
    private let channel: any Channel

    var upgradeHead: HTTPRequestHead? { lock.withLock { head } }
    var port: Int { channel.localAddress?.port ?? 0 }

    private init(channel: any Channel) {
        self.channel = channel
    }

    static func start(group: MultiThreadedEventLoopGroup) async throws -> FakeBastionServer {
        let box = HeadBox()
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                box.set(head)
                // Sin subprotocolo: no se devuelve Sec-WebSocket-Protocol.
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                }
            }
        )
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let server = FakeBastionServer(channel: channel)
        box.onSet = { head in server.lock.withLock { server.head = head } }
        return server
    }

    func stop() async {
        try? await channel.close()
    }

    final class HeadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: HTTPRequestHead?
        private var callback: (@Sendable (HTTPRequestHead) -> Void)?

        var onSet: (@Sendable (HTTPRequestHead) -> Void)? {
            get { lock.withLock { callback } }
            set {
                let replay = lock.withLock { () -> HTTPRequestHead? in
                    callback = newValue
                    return pending
                }
                if let replay { newValue?(replay) }
            }
        }

        func set(_ head: HTTPRequestHead) {
            let callback = lock.withLock { () -> (@Sendable (HTTPRequestHead) -> Void)? in
                pending = head
                return self.callback
            }
            callback?(head)
        }
    }

    final class EchoHandler: ChannelInboundHandler {
        typealias InboundIn = WebSocketFrame
        typealias OutboundOut = WebSocketFrame

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = unwrapInboundIn(data)
            switch frame.opcode {
            case .binary:
                let echo = WebSocketFrame(fin: true, opcode: .binary, data: frame.unmaskedData)
                context.writeAndFlush(wrapOutboundOut(echo), promise: nil)
            case .connectionClose:
                let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: context.channel.allocator.buffer(capacity: 0))
                context.writeAndFlush(wrapOutboundOut(close), promise: nil)
                context.close(promise: nil)
            default:
                break
            }
        }
    }
}

@Suite("WebSocketKitConnector contra un servidor /webtunnelv2 falso")
struct WebSocketKitConnectorTests {
    @Test("Upgrade con Origin, sin Authorization ni subprotocolo; eco binario de 10 000 B")
    func upgradeAndEcho() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await FakeBastionServer.start(group: group)

        let tokens = BastionSessionTokens(authToken: "auth", nodeId: "node-7", websocketToken: "wsTokenSecret123")
        let bastion = WebSocketRequest.bastion(dnsName: "bst-1.bastion.azure.com", tokens: tokens)
        // Mismo path, query y headers; solo cambia el transporte a ws://127.0.0.1.
        let request = WebSocketRequest(
            scheme: "ws", host: "127.0.0.1", port: server.port,
            path: bastion.path, query: bastion.query, headers: bastion.headers
        )

        let socket = try await WebSocketKitConnector(group: group, connectTimeout: .seconds(5)).connect(request)
        let payload = TunnelPumpTests.payload(10_000)
        try await socket.send(payload)
        var echoed = Data()
        for await message in socket.inbound {
            guard case .binary(let data) = message else { continue }
            echoed.append(data)
            if echoed.count >= payload.count { break }
        }
        await socket.close()

        #expect(echoed == payload)
        let head = try #require(server.upgradeHead)
        #expect(head.uri == "/webtunnelv2/wsTokenSecret123?X-Node-Id=node-7")
        #expect(head.headers["Origin"] == ["https://bst-1.bastion.azure.com"])
        #expect(head.headers["Authorization"].isEmpty)
        #expect(head.headers["Sec-WebSocket-Protocol"].isEmpty)
        #expect(head.headers["Sec-WebSocket-Version"] == ["13"])

        await server.stop()
        try await group.shutdownGracefully()
    }
}
