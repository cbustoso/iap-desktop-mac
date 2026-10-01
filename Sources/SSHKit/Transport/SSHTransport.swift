// T-SSH-1 (CBU-37) — spike del stack SSH sobre swift-nio-ssh.
// Ver specs/ssh/transport-decision.md. Alcance mínimo: connect TCP → handshake
// SSH → auth `publickey` → canal `session` con pty + shell. T-SSH-4 lo
// sustituye por `SshSession`/`SshChannel` sobre el stream de TunnelKit.
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Errores del spike de transporte. T-SSH-4 los unifica en `SshError`.
public enum SSHTransportError: Error, Sendable, Equatable {
    case hostKeyRejected
    case authenticationFailed
    case channelRejected
    case shellRejected
}

/// Decide si se acepta la host key del servidor.
/// T-SSH-7 implementa TOFU/confirmación; aquí solo pin explícito o test.
public struct SSHHostKeyPolicy: Sendable {
    let accepts: @Sendable (NIOSSHPublicKey) -> Bool

    public init(accepts: @escaping @Sendable (NIOSSHPublicKey) -> Bool) {
        self.accepts = accepts
    }

    /// Solo acepta exactamente esta host key.
    public static func pinned(_ expected: NIOSSHPublicKey) -> SSHHostKeyPolicy {
        SSHHostKeyPolicy { $0 == expected }
    }

    /// Acepta cualquier host key. SOLO para tests/spike contra un mock local.
    public static let acceptAnyForTesting = SSHHostKeyPolicy { _ in true }
}

/// Parámetros del pty remoto.
public struct SSHTerminalSize: Sendable, Equatable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = columns
        self.rows = rows
    }
}

public enum SSHTransport {
    /// Conecta a `host:port` (el listener local del túnel IAP, como
    /// `SshConnection(IPEndPoint)` en el original), autentica con `privateKey`
    /// (`publickey`; ECDSA P-256/384/521 o Ed25519) y abre un shell con pty.
    @available(*, deprecated, message: "Usa SshSession.connect(...) + openShell() (CBU-40/41)")
    public static func openShell(
        host: String,
        port: Int,
        username: String,
        privateKey: NIOSSHPrivateKey,
        hostKeyPolicy: SSHHostKeyPolicy,
        terminal: SSHTerminalSize = .init(),
        term: String = "xterm-256color"
    ) async throws -> SSHShellSession {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let firstError = FirstErrorBox()
        do {
            let connection = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    // Delegados y handler no son Sendable: se crean aquí, en el
                    // event loop del canal, a partir de valores Sendable.
                    channel.eventLoop.makeCompletedFuture {
                        let configuration = SSHClientConfiguration(
                            userAuthDelegate: PublicKeyAuthDelegate(
                                username: username, key: privateKey, firstError: firstError),
                            serverAuthDelegate: HostKeyDelegate(policy: hostKeyPolicy, firstError: firstError))
                        try channel.pipeline.syncOperations.addHandlers(
                            NIOSSHHandler(
                                role: .client(configuration),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: nil),
                            // Sin esto, un fallo de auth/host key deja la conexión
                            // abierta y `openShell` esperando para siempre.
                            CloseOnErrorHandler(firstError: firstError))
                    }
                }
                .connect(host: host, port: port)
                .get()

            let (output, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            let shell: any Channel
            do {
                shell = try await openShellChannel(
                    on: connection, output: continuation, terminal: terminal, term: term,
                    firstError: firstError)
            } catch {
                continuation.finish()
                try? await connection.close()
                throw error
            }
            return SSHShellSession(group: group, connection: connection, shell: shell, output: output)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private static func openShellChannel(
        on connection: any Channel,
        output: AsyncStream<Data>.Continuation,
        terminal: SSHTerminalSize,
        term: String,
        firstError: FirstErrorBox
    ) async throws -> any Channel {
        let channelPromise = connection.eventLoop.makePromise(of: Channel.self)
        let shellAccepted = connection.eventLoop.makePromise(of: Void.self)

        connection.eventLoop.execute {
            do {
                let ssh = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(channelPromise, channelType: .session) { child, type in
                    guard type == .session else {
                        return child.eventLoop.makeFailedFuture(SSHTransportError.channelRejected)
                    }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            ShellChannelHandler(output: output, shellAccepted: shellAccepted))
                    }
                }
            } catch {
                channelPromise.fail(error)
            }
        }
        // Si el handshake o la auth fallan, `CloseOnErrorHandler` cierra el
        // canal padre: se propaga aquí el primer error tipado (auth, host key…).
        connection.closeFuture.whenComplete { _ in
            let error = firstError.value ?? SSHTransportError.authenticationFailed
            channelPromise.fail(error)
            shellAccepted.fail(error)
        }

        do {
            return try await requestShell(
                on: try await channelPromise.futureResult.get(),
                shellAccepted: shellAccepted, terminal: terminal, term: term)
        } catch {
            // NIOSSH falla la creación pendiente con `ChannelError.eof` al caer la
            // conexión; el motivo real (auth, host key) lo dejaron los delegados.
            throw firstError.value ?? error
        }
    }

    private static func requestShell(
        on shell: any Channel,
        shellAccepted: EventLoopPromise<Void>,
        terminal: SSHTerminalSize,
        term: String
    ) async throws -> any Channel {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: term,
            terminalCharacterWidth: terminal.columns,
            terminalRowHeight: terminal.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:]))
        try await shell.triggerUserOutboundEvent(pty).get()
        try await shell.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true)).get()
        try await shellAccepted.futureResult.get()
        return shell
    }
}

/// Shell remoto abierto. `output` emite stdout+stderr tal cual (bytes crudos;
/// la decodificación UTF-8 en streaming es de T-SSH-4).
public final class SSHShellSession: Sendable {
    public let output: AsyncStream<Data>
    private let group: MultiThreadedEventLoopGroup
    private let connection: any Channel
    private let shell: any Channel

    init(group: MultiThreadedEventLoopGroup, connection: any Channel, shell: any Channel, output: AsyncStream<Data>) {
        self.group = group
        self.connection = connection
        self.shell = shell
        self.output = output
    }

    public func write(_ data: Data) async throws {
        var buffer = shell.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await shell.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }

    public func resize(_ size: SSHTerminalSize) async throws {
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0)
        try await shell.triggerUserOutboundEvent(request).get()
    }

    public func close() async {
        try? await shell.close()
        try? await connection.close()
        try? await group.shutdownGracefully()
    }
}

// MARK: - Delegados y handlers (confinados al event loop)

/// Primer error visto en la conexión. `@unchecked Sendable`: acceso bajo `lock`.
final class FirstErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any Error)?

    var value: (any Error)? { lock.withLock { stored } }

    func record(_ error: any Error) {
        lock.withLock { if stored == nil { stored = error } }
    }
}

/// Tras `NIOSSHHandler`: registra el error (si los delegados no dejaron ya el
/// motivo tipado) y cierra la conexión para que `openShell` no espere siempre.
private final class CloseOnErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let firstError: FirstErrorBox

    init(firstError: FirstErrorBox) {
        self.firstError = firstError
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        firstError.record(error)
        context.close(promise: nil)
    }
}

/// Ofrece una única vez `publickey` con la llave dada; si el servidor la
/// rechaza, falla (sin probar otros métodos: sin password en IAP Desktop).
private final class PublicKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let key: NIOSSHPrivateKey
    private let firstError: FirstErrorBox
    private var offered = false

    init(username: String, key: NIOSSHPrivateKey, firstError: FirstErrorBox) {
        self.username = username
        self.key = key
        self.firstError = firstError
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            // Se registra antes de fallar: lo que llega luego al pipeline es
            // solo el EOF del cierre, sin el motivo.
            firstError.record(SSHTransportError.authenticationFailed)
            nextChallengePromise.fail(SSHTransportError.authenticationFailed)
            return
        }
        offered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: key))))
    }
}

private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let policy: SSHHostKeyPolicy
    private let firstError: FirstErrorBox

    init(policy: SSHHostKeyPolicy, firstError: FirstErrorBox) {
        self.policy = policy
        self.firstError = firstError
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if policy.accepts(hostKey) {
            validationCompletePromise.succeed(())
        } else {
            firstError.record(SSHTransportError.hostKeyRejected)
            validationCompletePromise.fail(SSHTransportError.hostKeyRejected)
        }
    }
}

/// Canal `session`: reenvía stdout/stderr a `output` y señala la respuesta
/// a la petición de shell.
private final class ShellChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let output: AsyncStream<Data>.Continuation
    private let shellAccepted: EventLoopPromise<Void>

    init(output: AsyncStream<Data>.Continuation, shellAccepted: EventLoopPromise<Void>) {
        self.output = output
        self.shellAccepted = shellAccepted
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Permite que el servidor cierre su lado (EOF) sin cerrar el nuestro.
        // Síncrono: ya estamos en el event loop del canal.
        do {
            try context.channel.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        } catch {
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        output.yield(Data(buffer.readableBytesView))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            shellAccepted.succeed(())
        case is ChannelFailureEvent:
            shellAccepted.fail(SSHTransportError.shellRejected)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        output.finish()
        shellAccepted.fail(SSHTransportError.shellRejected)  // no-op si ya se completó
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        output.finish()
        context.close(promise: nil)
    }
}
