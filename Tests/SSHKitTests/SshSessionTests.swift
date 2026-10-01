// T-SSH-4 (CBU-40): SshSession/SshChannel contra el MockSSHServer.
// Reconexión fuera de alcance (CBU-42).
import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import SSHKit

// MARK: - Transporte de test

/// `SshByteStream` sobre TCP que trocea envíos y recepciones en fragmentos de
/// 1–16 bytes (deterministas), como un relay que entrega DATA arbitrarios.
private final class ChunkingTCPByteStream: SshByteStream {
    private static let chunkSizes = [1, 7, 3, 16, 2, 11, 5]

    private let channel: any Channel
    private let group: MultiThreadedEventLoopGroup
    private let received: AsyncStream<Data>
    private let counters: Counters

    var bytesSent: Int { counters.sent }
    var bytesReceived: Int { counters.received }

    private init(
        channel: any Channel, group: MultiThreadedEventLoopGroup, received: AsyncStream<Data>, counters: Counters
    ) {
        self.channel = channel
        self.group = group
        self.received = received
        self.counters = counters
    }

    static func connect(port: Int) async throws -> ChunkingTCPByteStream {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let counters = Counters()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        ChunkingReader(continuation: continuation, counters: counters))
                }
            }
            .connect(host: "127.0.0.1", port: port).get()
        return ChunkingTCPByteStream(channel: channel, group: group, received: stream, counters: counters)
    }

    func send(_ data: Data) async throws {
        var offset = 0
        var index = 0
        while offset < data.count {
            let size = min(Self.chunkSizes[index % Self.chunkSizes.count], data.count - offset)
            var buffer = channel.allocator.buffer(capacity: size)
            buffer.writeBytes(data[data.startIndex + offset ..< data.startIndex + offset + size])
            try await channel.writeAndFlush(buffer).get()
            offset += size
            index += 1
        }
        counters.addSent(data.count)
    }

    func incoming() -> AsyncStream<Data> { received }

    func close() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }

    /// `@unchecked Sendable`: acceso bajo `lock`.
    final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var sentBytes = 0
        private var receivedBytes = 0

        var sent: Int { lock.withLock { sentBytes } }
        var received: Int { lock.withLock { receivedBytes } }

        func addSent(_ n: Int) { lock.withLock { sentBytes += n } }
        func addReceived(_ n: Int) { lock.withLock { receivedBytes += n } }
    }

    private final class ChunkingReader: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private let continuation: AsyncStream<Data>.Continuation
        private let counters: Counters
        private var index = 0

        init(continuation: AsyncStream<Data>.Continuation, counters: Counters) {
            self.continuation = continuation
            self.counters = counters
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            counters.addReceived(buffer.readableBytes)
            while buffer.readableBytes > 0 {
                let size = min(chunkSizes[index % chunkSizes.count], buffer.readableBytes)
                index += 1
                continuation.yield(Data(buffer.readSlice(length: size)!.readableBytesView))
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            continuation.finish()
            context.fireChannelInactive()
        }
    }
}

// MARK: - Helpers

private func newUserKey() -> NIOSSHPrivateKey {
    NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
}

/// Lee `output` hasta que el texto acumulado contenga `marker`.
private func read(until marker: String, from iterator: inout AsyncStream<String>.Iterator) async -> String {
    var text = ""
    while !text.contains(marker), let chunk = await iterator.next() { text += chunk }
    return text
}

/// Servidor TCP que acepta y nunca habla SSH (para el timeout).
private func silentServer() async throws -> (port: Int, close: @Sendable () async -> Void) {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel = try await ServerBootstrap(group: group)
        .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
        .bind(host: "127.0.0.1", port: 0).get()
    return (channel.localAddress!.port!, {
        try? await channel.close()
        try? await group.shutdownGracefully()
    })
}

// MARK: - Tests

@Suite("SshSession / SshChannel", .serialized, .timeLimit(.minutes(1)))
struct SshSessionTests {
    @Test func shellOverChunkedByteStream() async throws {
        let key = newUserKey()
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: key.publicKey)
        let stream = try await ChunkingTCPByteStream.connect(port: server.port)
        let session = try await SshSession.connect(
            over: stream, username: "spike", privateKey: key, hostKeyPolicy: .pinned(server.hostKey))
        let shell = try await session.openShell(terminal: SSHTerminalSize(columns: 132, rows: 43))
        var output = shell.output.makeAsyncIterator()

        #expect(await read(until: "mock-shell$ ", from: &output).hasSuffix("mock-shell$ "))
        try await shell.write("hola ñandú €\n")
        #expect(await read(until: "mock-shell$ ", from: &output).contains("echo:hola ñandú €"))
        // Todo el tráfico SSH pasó por el stream troceado.
        #expect(stream.bytesSent > 0 && stream.bytesReceived > 0)

        let observed = server.observed
        #expect(observed.ptySize?.columns == 132)
        #expect(observed.ptySize?.rows == 43)
        await session.close()
        await server.shutdown()
    }

    @Test func multibyteSplitAcrossPacketsIsNotBroken() async throws {
        let key = newUserKey()
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: key.publicKey)
        let session = try await SshSession.connect(
            host: "127.0.0.1", port: server.port, username: "spike",
            privateKey: key, hostKeyPolicy: .pinned(server.hostKey))
        let shell = try await session.openShell()
        var output = shell.output.makeAsyncIterator()
        _ = await read(until: "mock-shell$ ", from: &output)

        // El mock envía "ñ€😀" en 9 paquetes SSH de 1 byte.
        try await shell.write("split\n")
        let text = await read(until: "mock-shell$ ", from: &output)
        #expect(text.contains("ñ€😀"))
        #expect(!text.contains("\u{FFFD}"))
        await session.close()
        await server.shutdown()
    }

    @Test func resizeReachesRemotePty() async throws {
        let key = newUserKey()
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: key.publicKey)
        let session = try await SshSession.connect(
            host: "127.0.0.1", port: server.port, username: "spike",
            privateKey: key, hostKeyPolicy: .pinned(server.hostKey))
        let shell = try await session.openShell()
        var output = shell.output.makeAsyncIterator()
        _ = await read(until: "mock-shell$ ", from: &output)

        try await shell.resize(SSHTerminalSize(columns: 100, rows: 30))
        try await shell.resize(SSHTerminalSize(columns: 160, rows: 50))
        // Ida y vuelta para asegurar que el servidor procesó los window-change.
        try await shell.write("ping\n")
        _ = await read(until: "echo:ping", from: &output)
        #expect(server.observed.resizes == [100, 160])
        #expect(shell.isOpen)  // el resize no cierra el canal
        await session.close()
        await server.shutdown()
    }

    @Test func drainReadsEverythingUntilExitAndReportsStatus() async throws {
        let key = newUserKey()
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: key.publicKey)
        let session = try await SshSession.connect(
            host: "127.0.0.1", port: server.port, username: "spike",
            privateKey: key, hostKeyPolicy: .pinned(server.hostKey))
        let shell = try await session.openShell()

        try await shell.write("uno\ndos\nexit 3\n")
        let all = await shell.drain()
        #expect(all.hasPrefix("mock-shell$ "))
        #expect(all.contains("echo:uno"))
        #expect(all.contains("echo:dos"))
        #expect(all.hasSuffix("bye\r\n"))
        #expect(shell.exitStatus == 3)
        #expect(!shell.isOpen)
        // La conexión sigue viva tras cerrar el canal: se puede abrir otro.
        #expect(await session.isConnected)
        await session.close()
        await server.shutdown()
    }

    @Test func authenticatedConnectionIsReusableForSubsystems() async throws {
        let key = newUserKey()
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: key.publicKey)
        let session = try await SshSession.connect(
            host: "127.0.0.1", port: server.port, username: "spike",
            privateKey: key, hostKeyPolicy: .pinned(server.hostKey))

        let shell = try await session.openShell()
        let sftpLike = try await session.openSubsystem("sftp")
        let payload = Data([0x00, 0xFF, 0x10, 0xC3])  // bytes crudos, no UTF-8
        try await sftpLike.write(payload)
        var raw = sftpLike.output.makeAsyncIterator()
        var echoed = Data()
        while echoed.count < payload.count, let chunk = await raw.next() { echoed += chunk }
        #expect(echoed == payload)
        #expect(server.observed.subsystems == ["sftp"])
        #expect(shell.isOpen)  // ambos canales conviven en la misma conexión
        await session.close()
        await server.shutdown()
    }

    @Test func closedSessionRefusesNewChannels() async throws {
        let key = newUserKey()
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: key.publicKey)
        let session = try await SshSession.connect(
            host: "127.0.0.1", port: server.port, username: "spike",
            privateKey: key, hostKeyPolicy: .pinned(server.hostKey))
        await session.close()
        await #expect(throws: SshSessionError.sessionClosed) { _ = try await session.openShell() }
        await server.shutdown()
    }

    @Test func wrongKeyAndWrongHostKeyAreTyped() async throws {
        let key = newUserKey()
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: key.publicKey)
        // Regresión: NIOSSH no cierra ante un rechazo; sin fallar en el acto,
        // cada intento esperaba el timeout completo (30 s).
        let started = ContinuousClock.now
        await #expect(throws: SSHTransportError.authenticationFailed) {
            _ = try await SshSession.connect(
                host: "127.0.0.1", port: server.port, username: "spike",
                privateKey: newUserKey(), hostKeyPolicy: .pinned(server.hostKey))
        }
        let otherHost = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        await #expect(throws: SSHTransportError.hostKeyRejected) {
            _ = try await SshSession.connect(
                host: "127.0.0.1", port: server.port, username: "spike",
                privateKey: key, hostKeyPolicy: .pinned(otherHost))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        await server.shutdown()
    }

    @Test func handshakeTimeoutIsTyped() async throws {
        let silent = try await silentServer()
        let started = ContinuousClock.now
        await #expect(throws: SshSessionError.timeout) {
            _ = try await SshSession.connect(
                host: "127.0.0.1", port: silent.port, username: "spike",
                privateKey: newUserKey(), hostKeyPolicy: .acceptAnyForTesting,
                timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        await silent.close()
    }

    @Test func descriptionRedactsKey() async throws {
        let key = newUserKey()
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: key.publicKey)
        let session = try await SshSession.connect(
            host: "127.0.0.1", port: server.port, username: "spike",
            privateKey: key, hostKeyPolicy: .pinned(server.hostKey))
        let text = String(describing: session)
        #expect(text.contains("<redacted>"))
        #expect(!text.contains(String(openSSHPublicKey: key.publicKey)))
        await session.close()
        await server.shutdown()
    }
}
