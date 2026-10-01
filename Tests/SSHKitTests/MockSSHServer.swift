// Servidor SSH mock en loopback (NIOSSH rol servidor) para el spike T-SSH-1.
// Solo tests: acepta `publickey` de una llave concreta y ofrece un shell falso
// que hace eco ("echo:<línea>") y termina con "exit".
import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

final class MockSSHServer: Sendable {
    /// Lo que el cliente pidió al servidor (para aserciones).
    struct Observed: Sendable, Equatable {
        var ptyTerm: String?
        var ptySize: (columns: Int, rows: Int)?
        var shellRequested = false
        var resizes: [Int] = []  // columnas de cada window-change
        var subsystems: [String] = []

        static func == (lhs: Observed, rhs: Observed) -> Bool {
            lhs.ptyTerm == rhs.ptyTerm && lhs.ptySize?.columns == rhs.ptySize?.columns
                && lhs.ptySize?.rows == rhs.ptySize?.rows && lhs.shellRequested == rhs.shellRequested
                && lhs.resizes == rhs.resizes && lhs.subsystems == rhs.subsystems
        }
    }

    let port: Int
    let hostKey: NIOSSHPublicKey
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let recorder: Recorder

    var observed: Observed { recorder.value }

    private init(
        port: Int, hostKey: NIOSSHPublicKey, group: MultiThreadedEventLoopGroup,
        channel: any Channel, recorder: Recorder
    ) {
        self.port = port
        self.hostKey = hostKey
        self.group = group
        self.channel = channel
        self.recorder = recorder
    }

    static func start(username: String, authorizedKey: NIOSSHPublicKey) async throws -> MockSSHServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hostPrivateKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let recorder = Recorder()
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { child in
                    child.eventLoop.makeCompletedFuture {
                        let configuration = SSHServerConfiguration(
                            hostKeys: [hostPrivateKey],
                            userAuthDelegate: SingleKeyAuthDelegate(username: username, key: authorizedKey))
                        try child.pipeline.syncOperations.addHandler(
                            NIOSSHHandler(
                                role: .server(configuration),
                                allocator: child.allocator,
                                inboundChildChannelInitializer: { sessionChannel, _ in
                                    sessionChannel.eventLoop.makeCompletedFuture {
                                        try sessionChannel.pipeline.syncOperations.addHandler(
                                            FakeShellHandler(recorder: recorder))
                                    }
                                }))
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            guard let port = channel.localAddress?.port else {
                try? await channel.close()
                throw MockError.noPort
            }
            return MockSSHServer(
                port: port, hostKey: hostPrivateKey.publicKey, group: group,
                channel: channel, recorder: recorder)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func shutdown() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }

    private enum MockError: Error { case noPort }
}

/// `@unchecked Sendable`: todo acceso pasa por `lock`.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = MockSSHServer.Observed()

    var value: MockSSHServer.Observed { lock.withLock { storage } }

    func update(_ body: (inout MockSSHServer.Observed) -> Void) {
        lock.withLock { body(&storage) }
    }
}

private final class SingleKeyAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey
    private let username: String
    private let key: NIOSSHPublicKey

    init(username: String, key: NIOSSHPublicKey) {
        self.username = username
        self.key = key
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        // NIOSSH ya verificó la firma; aquí solo se autoriza usuario + llave.
        guard request.username == username, case .publicKey(let offered) = request.request,
              offered.publicKey == key
        else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

/// Shell falso: prompt, eco por línea y `exit [n]` → exit-status n + cierre.
/// `split` envía "ñ€😀" byte a byte (un paquete SSH por byte) para probar la
/// decodificación UTF-8 en streaming. Un `subsystem` hace eco de bytes crudos.
private final class FakeShellHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let recorder: Recorder
    private var pending = ""
    private var rawEcho = false

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let pty as SSHChannelRequestEvent.PseudoTerminalRequest:
            recorder.update {
                $0.ptyTerm = pty.term
                $0.ptySize = (pty.terminalCharacterWidth, pty.terminalRowHeight)
            }
            if pty.wantReply { context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        case let shell as SSHChannelRequestEvent.ShellRequest:
            recorder.update { $0.shellRequested = true }
            if shell.wantReply { context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            send("mock-shell$ ", context: context)
        case let resize as SSHChannelRequestEvent.WindowChangeRequest:
            recorder.update { $0.resizes.append(resize.terminalCharacterWidth) }
        case let subsystem as SSHChannelRequestEvent.SubsystemRequest:
            recorder.update { $0.subsystems.append(subsystem.subsystem) }
            rawEcho = true
            if subsystem.wantReply { context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(let buffer) = unwrapInboundIn(data).data else { return }
        if rawEcho {
            context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
            return
        }
        pending += String(buffer: buffer)
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending = String(pending[pending.index(after: newline)...])
            if line == "exit" || line.hasPrefix("exit ") {
                let status = Int(line.dropFirst("exit".count).trimmingCharacters(in: .whitespaces)) ?? 0
                send("bye\r\n", context: context)
                let channel = context.channel
                channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: status))
                    .whenComplete { _ in channel.close(promise: nil) }
                return
            }
            if line == "split" {
                for byte in Array("ñ€😀".utf8) {
                    var one = context.channel.allocator.buffer(capacity: 1)
                    one.writeInteger(byte)
                    context.writeAndFlush(
                        wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(one))), promise: nil)
                }
                send("\r\nmock-shell$ ", context: context)
                continue
            }
            send("echo:\(line)\r\nmock-shell$ ", context: context)
        }
    }

    private func send(_ text: String, context: ChannelHandlerContext) {
        let buffer = context.channel.allocator.buffer(string: text)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
    }
}
