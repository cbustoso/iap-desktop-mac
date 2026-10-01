import Foundation
import NIOCore
import NIOSSH

/// Canal shell interactivo (paridad `SshShellChannel` / `IPseudoTerminal`):
/// `write` / `resize` / `drain` y salida ya decodificada como UTF-8.
///
/// `output` es de un solo consumidor: o se itera, o se llama a `drain()`,
/// nunca ambos a la vez.
public final class SshChannel: Sendable {
    /// stdout + stderr decodificados en streaming (sin romper multibyte).
    public let output: AsyncStream<String>
    private let channel: any Channel
    private let exit: ExitStatusBox
    private let link: LinkStateHub

    init(channel: any Channel, output: AsyncStream<String>, exit: ExitStatusBox, link: LinkStateHub) {
        self.channel = channel
        self.output = output
        self.exit = exit
        self.link = link
    }

    /// Estado del enlace (CBU-42): `.reconnecting` mientras el túnel se
    /// reanuda (el canal sigue siendo este), `.lost` si no se pudo.
    public var linkState: SshLinkState { link.state }

    public func linkStateUpdates() -> AsyncStream<SshLinkState> { link.updates() }

    public func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }

    public func write(_ text: String) async throws {
        try await write(Data(text.utf8))
    }

    /// Propaga el nuevo tamaño al pty remoto sin cerrar el canal.
    public func resize(_ size: SSHTerminalSize) async throws {
        try await channel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: size.columns,
                terminalRowHeight: size.rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0)
        ).get()
    }

    /// Consume `output` hasta que el canal se cierra y devuelve todo el texto.
    public func drain() async -> String {
        var text = ""
        for await chunk in output { text += chunk }
        return text
    }

    /// `exit-status` remoto, si el servidor lo envió antes de cerrar.
    public var exitStatus: Int? { exit.value }

    public var isOpen: Bool { channel.isActive }

    public func close() async {
        try? await channel.close()
    }
}

/// Canal de subsistema con bytes crudos (p. ej. `sftp`, REQ-SSH-6): misma
/// conexión autenticada, sin pty ni decodificación de texto.
public final class SshDataChannel: Sendable {
    public let output: AsyncStream<Data>
    private let channel: any Channel

    init(channel: any Channel, output: AsyncStream<Data>) {
        self.channel = channel
        self.output = output
    }

    public func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }

    public var isOpen: Bool { channel.isActive }

    public func close() async {
        try? await channel.close()
    }
}

// MARK: - Handler del canal (confinado al event loop)

/// `@unchecked Sendable`: acceso bajo `lock`.
final class ExitStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?

    var value: Int? { lock.withLock { stored } }

    func set(_ status: Int) { lock.withLock { stored = status } }
}

/// Reenvía los datos del canal `session` y resuelve la respuesta a la última
/// petición con `wantReply` (shell o subsystem).
final class SessionChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    enum Sink {
        case text(AsyncStream<String>.Continuation)
        case bytes(AsyncStream<Data>.Continuation)
    }

    private let sink: Sink
    private let requestReply: EventLoopPromise<Void>
    private let exit: ExitStatusBox
    private var decoder = StreamingDecoder()

    init(sink: Sink, requestReply: EventLoopPromise<Void>, exit: ExitStatusBox) {
        self.sink = sink
        self.requestReply = requestReply
        self.exit = exit
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // EOF remoto sin cerrar nuestro lado (necesario para leer hasta el final).
        do {
            try context.channel.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        } catch {
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(let buffer) = unwrapInboundIn(data).data else { return }
        let bytes = Data(buffer.readableBytesView)
        switch sink {
        case .text(let continuation):
            let text = decoder.decode(bytes)
            if !text.isEmpty { continuation.yield(text) }
        case .bytes(let continuation):
            continuation.yield(bytes)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            requestReply.succeed(())
        case is ChannelFailureEvent:
            requestReply.fail(SSHTransportError.shellRejected)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exit.set(status.exitStatus)
        case let half as ChannelEvent where half == .inputClosed:
            // El servidor terminó de enviar: cerramos el canal por completo.
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finishSink()
        requestReply.fail(SshSessionError.channelClosed)  // no-op si ya respondió
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    private func finishSink() {
        switch sink {
        case .text(let continuation):
            let tail = decoder.finish()
            if !tail.isEmpty { continuation.yield(tail) }
            continuation.finish()
        case .bytes(let continuation):
            continuation.finish()
        }
    }
}
