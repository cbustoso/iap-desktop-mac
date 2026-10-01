import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Errores propios de la sesión. Auth y host key siguen en `SSHTransportError`.
public enum SshSessionError: Error, Sendable, Equatable {
    /// Handshake + auth no terminó a tiempo (`ConnectionTimeout` del original).
    case timeout
    /// El transporte (túnel IAP / TCP) se cerró antes de autenticar.
    case transportClosed
    /// La sesión ya se cerró; no se pueden abrir canales.
    case sessionClosed
    case channelClosed
    case socketPairFailed(errno: Int32)
}

/// Conexión SSH autenticada y reutilizable (REQ-SSH-6): sobre ella se abren
/// el shell (`openShell`) y otros canales (`openSubsystem`, p. ej. SFTP) sin
/// re-autenticar. La privada no aparece en ninguna descripción.
public actor SshSession: CustomStringConvertible {
    public nonisolated let username: String
    private let group: MultiThreadedEventLoopGroup
    private let connection: any Channel
    private let bridge: ByteStreamBridge?
    private var closed = false

    private init(username: String, group: MultiThreadedEventLoopGroup, connection: any Channel, bridge: ByteStreamBridge?) {
        self.username = username
        self.group = group
        self.connection = connection
        self.bridge = bridge
    }

    public nonisolated var description: String {
        "SshSession(username: \(username), key: <redacted>)"
    }

    // MARK: - Conexión

    /// Conecta sobre un flujo de bytes (p. ej. el `SshRelayStream` de TunnelKit).
    public static func connect(
        over stream: any SshByteStream,
        username: String,
        privateKey: NIOSSHPrivateKey,
        hostKeyPolicy: SSHHostKeyPolicy,
        timeout: Duration = .seconds(30)
    ) async throws -> SshSession {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let (sshSide, bridge) = try await ByteStreamBridge.start(stream: stream, group: group)
            do {
                let firstError = FirstErrorBox()
                let authenticated = group.next().makePromise(of: Void.self)
                let connection = try await bootstrap(
                    group: group, username: username, privateKey: privateKey,
                    hostKeyPolicy: hostKeyPolicy, firstError: firstError, authenticated: authenticated
                ).withConnectedSocket(sshSide).get()
                try await awaitAuthentication(
                    connection: connection, authenticated: authenticated, firstError: firstError, timeout: timeout)
                return SshSession(username: username, group: group, connection: connection, bridge: bridge)
            } catch {
                await bridge.close()
                throw error
            }
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// Conecta por TCP (listener local del túnel IAP, como `SshConnection(IPEndPoint)`).
    public static func connect(
        host: String,
        port: Int,
        username: String,
        privateKey: NIOSSHPrivateKey,
        hostKeyPolicy: SSHHostKeyPolicy,
        timeout: Duration = .seconds(30)
    ) async throws -> SshSession {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let firstError = FirstErrorBox()
            let authenticated = group.next().makePromise(of: Void.self)
            let connection = try await bootstrap(
                group: group, username: username, privateKey: privateKey,
                hostKeyPolicy: hostKeyPolicy, firstError: firstError, authenticated: authenticated
            )
            .connectTimeout(.nanoseconds(Int64(timeout.nanoseconds)))
            .connect(host: host, port: port).get()
            try await awaitAuthentication(
                connection: connection, authenticated: authenticated, firstError: firstError, timeout: timeout)
            return SshSession(username: username, group: group, connection: connection, bridge: nil)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private static func bootstrap(
        group: MultiThreadedEventLoopGroup,
        username: String,
        privateKey: NIOSSHPrivateKey,
        hostKeyPolicy: SSHHostKeyPolicy,
        firstError: FirstErrorBox,
        authenticated: EventLoopPromise<Void>
    ) -> ClientBootstrap {
        // Los delegados fallan `authenticated` en el acto: NIOSSH no cierra la
        // conexión ni emite error ante auth/host key rechazadas, y sin esto se
        // esperaría hasta el timeout.
        let failure = AuthFailure(firstError: firstError, authenticated: authenticated)
        return ClientBootstrap(group: group).channelInitializer { channel in
            // Delegados y handler no son Sendable: se crean en el event loop.
            channel.eventLoop.makeCompletedFuture {
                let configuration = SSHClientConfiguration(
                    userAuthDelegate: SessionPublicKeyAuthDelegate(
                        username: username, key: privateKey, failure: failure),
                    serverAuthDelegate: SessionHostKeyDelegate(policy: hostKeyPolicy, failure: failure))
                try channel.pipeline.syncOperations.addHandlers(
                    NIOSSHHandler(role: .client(configuration), allocator: channel.allocator, inboundChildChannelInitializer: nil),
                    AuthenticationWatcher(authenticated: authenticated, firstError: firstError))
            }
        }
    }

    private static func awaitAuthentication(
        connection: any Channel,
        authenticated: EventLoopPromise<Void>,
        firstError: FirstErrorBox,
        timeout: Duration
    ) async throws {
        let deadline = connection.eventLoop.scheduleTask(in: .nanoseconds(Int64(timeout.nanoseconds))) {
            firstError.record(SshSessionError.timeout)
            authenticated.fail(SshSessionError.timeout)
            connection.close(promise: nil)
        }
        defer { deadline.cancel() }
        do {
            try await authenticated.futureResult.get()
        } catch {
            try? await connection.close()
            throw firstError.value ?? error
        }
    }

    // MARK: - Canales sobre la conexión autenticada

    /// Abre un canal `session` con pty + shell.
    public func openShell(
        terminal: SSHTerminalSize = .init(),
        term: String = "xterm-256color"
    ) async throws -> SshChannel {
        let (output, continuation) = AsyncStream<String>.makeStream()
        let exit = ExitStatusBox()
        let child = try await openSessionChannel(sink: .text(continuation), exit: exit) { channel, reply in
            let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: false, term: term,
                terminalCharacterWidth: terminal.columns, terminalRowHeight: terminal.rows,
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))
            try await channel.triggerUserOutboundEvent(pty).get()
            try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true)).get()
            try await reply.futureResult.get()
        }
        return SshChannel(channel: child, output: output, exit: exit)
    }

    /// Abre un subsistema (`sftp`, …) con bytes crudos sobre la misma conexión.
    public func openSubsystem(_ name: String) async throws -> SshDataChannel {
        let (output, continuation) = AsyncStream<Data>.makeStream()
        let child = try await openSessionChannel(sink: .bytes(continuation), exit: ExitStatusBox()) { channel, reply in
            try await channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.SubsystemRequest(subsystem: name, wantReply: true)).get()
            try await reply.futureResult.get()
        }
        return SshDataChannel(channel: child, output: output)
    }

    private func openSessionChannel(
        sink: SessionChannelHandler.Sink,
        exit: ExitStatusBox,
        request: @Sendable (any Channel, EventLoopPromise<Void>) async throws -> Void
    ) async throws -> any Channel {
        guard !closed, connection.isActive else { throw SshSessionError.sessionClosed }
        let connection = self.connection
        let created = connection.eventLoop.makePromise(of: Channel.self)
        let reply = connection.eventLoop.makePromise(of: Void.self)
        connection.eventLoop.execute {
            do {
                let ssh = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(created, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            SessionChannelHandler(sink: sink, requestReply: reply, exit: exit))
                    }
                }
            } catch {
                created.fail(error)
            }
        }
        let child: any Channel
        do {
            child = try await created.futureResult.get()
        } catch {
            finish(sink)
            throw error
        }
        do {
            try await request(child, reply)
        } catch {
            try? await child.close()
            throw error
        }
        return child
    }

    private nonisolated func finish(_ sink: SessionChannelHandler.Sink) {
        switch sink {
        case .text(let continuation): continuation.finish()
        case .bytes(let continuation): continuation.finish()
        }
    }

    // MARK: - Ciclo de vida

    public var isConnected: Bool { !closed && connection.isActive }

    /// Cierra todos los canales, la conexión SSH y el transporte.
    public func close() async {
        guard !closed else { return }
        closed = true
        try? await connection.close()
        await bridge?.close()
        try? await group.shutdownGracefully()
    }
}

// MARK: - Delegados y handlers de la conexión (confinados al event loop)

/// Ofrece `publickey` una única vez; sin password (paridad IAP Desktop).
private final class SessionPublicKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let key: NIOSSHPrivateKey
    private let failure: AuthFailure
    private var offered = false

    init(username: String, key: NIOSSHPrivateKey, failure: AuthFailure) {
        self.username = username
        self.key = key
        self.failure = failure
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            failure.fail(SSHTransportError.authenticationFailed)
            nextChallengePromise.fail(SSHTransportError.authenticationFailed)
            return
        }
        offered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

private final class SessionHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let policy: SSHHostKeyPolicy
    private let failure: AuthFailure

    init(policy: SSHHostKeyPolicy, failure: AuthFailure) {
        self.policy = policy
        self.failure = failure
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if policy.accepts(hostKey) {
            validationCompletePromise.succeed(())
        } else {
            failure.fail(SSHTransportError.hostKeyRejected)
            validationCompletePromise.fail(SSHTransportError.hostKeyRejected)
        }
    }
}

/// Registra el motivo tipado y falla la espera de autenticación de inmediato.
private struct AuthFailure: Sendable {
    let firstError: FirstErrorBox
    let authenticated: EventLoopPromise<Void>

    func fail(_ error: SSHTransportError) {
        firstError.record(error)
        authenticated.fail(error)
    }
}

/// Tras `NIOSSHHandler`: resuelve `authenticated` con `UserAuthSuccessEvent`,
/// y ante error o cierre falla con el motivo registrado (auth, host key…).
private final class AuthenticationWatcher: ChannelInboundHandler {
    typealias InboundIn = Any

    private let authenticated: EventLoopPromise<Void>
    private let firstError: FirstErrorBox

    init(authenticated: EventLoopPromise<Void>, firstError: FirstErrorBox) {
        self.authenticated = authenticated
        self.firstError = firstError
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            authenticated.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        firstError.record(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        authenticated.fail(firstError.value ?? SshSessionError.transportClosed)  // no-op si ya autenticó
        context.fireChannelInactive()
    }
}

// MARK: - Puente SshByteStream ⇄ socket NIO

/// Conecta un `SshByteStream` con NIOSSH: un `socketpair` local cuyo extremo A
/// lleva el handler SSH y el extremo B bombea bytes hacia/desde el stream.
/// Así SSH corre sobre cualquier transporte (túnel IAP) sin reimplementar un
/// `Channel` NIO propio.
final class ByteStreamBridge: Sendable {
    private let channel: any Channel
    private let stream: any SshByteStream
    private let pumps: [Task<Void, Never>]

    private init(channel: any Channel, stream: any SshByteStream, pumps: [Task<Void, Never>]) {
        self.channel = channel
        self.stream = stream
        self.pumps = pumps
    }

    /// Devuelve el descriptor del extremo SSH y el puente ya bombeando.
    static func start(
        stream: any SshByteStream, group: MultiThreadedEventLoopGroup
    ) async throws -> (sshSide: NIOBSDSocket.Handle, bridge: ByteStreamBridge) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw SshSessionError.socketPairFailed(errno: errno)
        }
        var on: Int32 = 1
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        let (outbound, outboundContinuation) = AsyncStream<Data>.makeStream()
        let bridgeChannel: any Channel
        do {
            bridgeChannel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            BridgeSocketHandler(outbound: outboundContinuation))
                    }
                }
                .withConnectedSocket(fds[1]).get()
        } catch {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
            throw error
        }

        // socket → stream, en orden y con un único emisor.
        let send = Task {
            for await chunk in outbound {
                do {
                    try await stream.send(chunk)
                } catch {
                    break
                }
            }
            await stream.close()
            try? await bridgeChannel.close()
        }
        // stream → socket; fin del transporte = EOF para SSH.
        let receive = Task {
            for await chunk in stream.incoming() {
                var buffer = bridgeChannel.allocator.buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                do {
                    try await bridgeChannel.writeAndFlush(buffer).get()
                } catch {
                    break
                }
            }
            try? await bridgeChannel.close()
        }
        return (fds[0], ByteStreamBridge(channel: bridgeChannel, stream: stream, pumps: [send, receive]))
    }

    func close() async {
        try? await channel.close()
        for pump in pumps { pump.cancel() }
        await stream.close()
    }
}

/// Extremo B del socketpair: lo que escribe SSH sale hacia `outbound`.
private final class BridgeSocketHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let outbound: AsyncStream<Data>.Continuation

    init(outbound: AsyncStream<Data>.Continuation) {
        self.outbound = outbound
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        outbound.yield(Data(unwrapInboundIn(data).readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        outbound.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

private extension Duration {
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
