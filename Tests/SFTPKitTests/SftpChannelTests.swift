// GH-55: pipelining por request-id (respuestas fuera de orden), INIT/VERSION
// y `open(over:)` sobre una SshSession real (subsistema en la misma conexión;
// `.sessionLost` sin red si el enlace ya está perdido).
import CryptoKit
import Foundation
import IAPTestSupport
import NIOCore
import NIOPosix
import NIOSSH
import SSHKit
import Testing
import TunnelKit
@testable import SFTPKit

// MARK: - Servidor SFTP falso (transporte en memoria)

/// Responde VERSION al INIT y retiene las respuestas a REALPATH para
/// soltarlas en el orden que pida el test. `@unchecked`: estado bajo `lock`.
private final class FakeSftpServer: SftpTransport, @unchecked Sendable {
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var framer = SftpFramer()
    private(set) var held: [(id: UInt32, path: String)] = []
    private(set) var written: [SftpPacket] = []
    var versionReply: Data? = openSSHVersion
    private(set) var closed = false

    init() {
        (output, continuation) = AsyncStream<Data>.makeStream()
    }

    func write(_ data: Data) async throws {
        let reply: Data? = try lock.withLock {
            framer.append(data)
            var reply: Data?
            while let packet = try framer.next() {
                written.append(packet)
                switch packet.type {
                case .initialize:
                    reply = versionReply
                case .realpath:
                    var reader = SftpReader(packet.payload)
                    held.append((try reader.uint32(), try reader.text()))
                default:
                    break
                }
            }
            return reply
        }
        if let reply { continuation.yield(reply) }
    }

    var heldCount: Int { lock.withLock { held.count } }

    /// Responde a las peticiones retenidas en el orden de `order` (índices).
    func release(order: [Int]) {
        let requests = lock.withLock { held }
        for index in order {
            let (id, path) = requests[index]
            let packet = SftpPacket.request(.name, id: id) {
                $0.uint32(1)
                $0.string("/home/ada/\(path)")
                $0.string("")
                SftpAttributes().encode(into: &$0)
            }
            // Partido en dos mensajes del canal para ejercitar el reensamblado.
            let bytes = packet.encoded()
            continuation.yield(bytes.prefix(3))
            continuation.yield(bytes.dropFirst(3))
        }
    }

    func send(_ bytes: Data) { continuation.yield(bytes) }
    func finish() { continuation.finish() }

    func close() async {
        lock.withLock { closed = true }
        continuation.finish()
    }

    var isClosed: Bool { lock.withLock { closed } }
}

private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
}

@Suite("SftpRequestTable (GH-55)")
struct SftpRequestTableTests {
    @Test func outOfOrderResponsesReachTheirRequest() async throws {
        let table = SftpRequestTable()
        let ids = try (0..<3).map { _ in try table.reserve() }
        #expect(ids == [1, 2, 3])
        // La 3 llega antes de que nadie espere; luego 1 y 2 al revés.
        table.resolve(3, with: .handle(Data("c".utf8)))
        async let first = table.wait(1)
        async let second = table.wait(2)
        try await Task.sleep(for: .milliseconds(20))
        table.resolve(2, with: .handle(Data("b".utf8)))
        table.resolve(1, with: .handle(Data("a".utf8)))
        #expect(try await first == .handle(Data("a".utf8)))
        #expect(try await second == .handle(Data("b".utf8)))
        #expect(try await table.wait(3) == .handle(Data("c".utf8)))
        #expect(table.pendingCount == 0)
    }

    @Test func unknownIDIsIgnored() throws {
        let table = SftpRequestTable()
        #expect(!table.resolve(42, with: .data(Data())))
        _ = try table.reserve()
        #expect(table.pendingCount == 1)
    }

    @Test func failAllFailsPendingAndFutureRequests() async throws {
        let table = SftpRequestTable()
        let id = try table.reserve()
        let pending = Task { try await table.wait(id) }
        try await Task.sleep(for: .milliseconds(20))
        table.failAll(.channelClosed)
        await #expect(throws: SftpError.channelClosed) { try await pending.value }
        #expect(throws: SftpError.channelClosed) { try table.reserve() }
    }

    @Test func cancelReleasesID() async throws {
        let table = SftpRequestTable()
        let id = try table.reserve()
        table.cancel(id)
        #expect(table.pendingCount == 0)
        #expect(!table.resolve(id, with: .data(Data())))
    }
}

@Suite("SftpChannel INIT/VERSION (GH-55)", .timeLimit(.minutes(1)))
struct SftpChannelTests {
    @Test func openNegotiatesVersion3WithOpenSSHExtensions() async throws {
        let server = FakeSftpServer()
        let channel = try await SftpChannel.open(linkState: .connected, timeout: .seconds(5)) { server }
        #expect(channel.version == 3)
        #expect(channel.extensions["posix-rename@openssh.com"] == "1")
        #expect(server.written.first?.encoded() == hex("000000050100000003"))
        await channel.close()
        #expect(server.isClosed)
    }

    @Test func pipelinedRequestsResolveOutOfOrder() async throws {
        let server = FakeSftpServer()
        let channel = try await SftpChannel.open(linkState: .connected, timeout: .seconds(5)) { server }
        async let a = channel.realPath("a")
        async let b = channel.realPath("b")
        async let c = channel.realPath("c")
        await waitUntil { server.heldCount == 3 }  // las tres en vuelo a la vez
        let order = server.held.map(\.path)
        // Respuestas en orden inverso al de llegada.
        server.release(order: [2, 1, 0])
        let results = try await [a, b, c]
        #expect(results == ["/home/ada/a", "/home/ada/b", "/home/ada/c"])
        #expect(Set(order) == ["a", "b", "c"])
        await channel.close()
    }

    @Test func lostOrClosedSessionFailsWithoutOpeningTransport() async {
        for state in [SshLinkState.lost(.reconnectExhausted), .closed] {
            var opened = false
            await #expect(throws: SftpError.sessionLost) {
                _ = try await SftpChannel.open(linkState: state, timeout: .seconds(1)) {
                    opened = true
                    return FakeSftpServer()
                }
            }
            #expect(!opened)  // sin red: ni siquiera se pide el subsistema
        }
    }

    @Test func unsupportedVersionIsRejectedAndClosed() async {
        let server = FakeSftpServer()
        server.versionReply = SftpPacket(type: .version, payload: hex("00000006")).encoded()
        await #expect(throws: SftpError.unsupportedVersion(negotiated: 6)) {
            _ = try await SftpChannel.open(linkState: .connected, timeout: .seconds(5)) { server }
        }
        #expect(server.isClosed)
    }

    @Test func silentServerTimesOut() async {
        let server = FakeSftpServer()
        server.versionReply = nil
        await #expect(throws: SftpError.timeout) {
            _ = try await SftpChannel.open(linkState: .connected, timeout: .milliseconds(100)) { server }
        }
    }

    @Test func channelClosingFailsPendingRequests() async throws {
        let server = FakeSftpServer()
        let channel = try await SftpChannel.open(linkState: .connected, timeout: .seconds(5)) { server }
        let pending = Task { try await channel.realPath("x") }
        await waitUntil { server.heldCount == 1 }
        server.finish()  // el servidor cierra el canal
        await #expect(throws: SftpError.channelClosed) { try await pending.value }
        await channel.close()
    }

    @Test func statusErrorsAreTyped() async throws {
        let server = FakeSftpServer()
        let channel = try await SftpChannel.open(linkState: .connected, timeout: .seconds(5)) { server }
        let missing = Task { try await channel.realPath("/nope") }
        await waitUntil { server.heldCount == 1 }
        let id = server.held[0].id
        server.send(SftpPacket.request(.status, id: id) {
            $0.uint32(SftpStatus.noSuchFile)
            $0.string("No such file")
            $0.string("")
        }.encoded())
        await #expect(throws: SftpError.fileNotFound) { try await missing.value }
        await channel.close()
    }
}

// MARK: - Sobre una SshSession real

/// Flujo TCP al mock SSH con estado de enlace controlable (simula el túnel
/// IAP). `@unchecked Sendable`: estado bajo `lock`.
private final class ControlledTCPStream: SshByteStream, @unchecked Sendable {
    private let channel: any Channel
    private let group: MultiThreadedEventLoopGroup
    private let inbound: AsyncStream<Data>
    private let states: AsyncStream<SshLinkState>
    private let statesContinuation: AsyncStream<SshLinkState>.Continuation

    private init(channel: any Channel, group: MultiThreadedEventLoopGroup, inbound: AsyncStream<Data>) {
        self.channel = channel
        self.group = group
        self.inbound = inbound
        (states, statesContinuation) = AsyncStream<SshLinkState>.makeStream()
        statesContinuation.yield(.connected)
    }

    static func connect(port: Int) async throws -> ControlledTCPStream {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let (inbound, continuation) = AsyncStream<Data>.makeStream()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Forwarder(continuation: continuation))
                }
            }
            .connect(host: "127.0.0.1", port: port).get()
        return ControlledTCPStream(channel: channel, group: group, inbound: inbound)
    }

    func send(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    func incoming() -> AsyncStream<Data> { inbound }
    func linkStates() async -> AsyncStream<SshLinkState> { states }

    /// El túnel se pierde (los reintentos se agotaron): la conexión TCP sigue
    /// viva, solo el estado del enlace cambia.
    func markLost() { statesContinuation.yield(.lost(.reconnectExhausted)) }

    private let lock = NSLock()
    private var closed = false

    /// Idempotente: `SshSession.close()` ya cierra el flujo; el test también.
    func close() async {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        statesContinuation.finish()
        try? await channel.close()
        try? await group.shutdownGracefully()
    }

    private final class Forwarder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let continuation: AsyncStream<Data>.Continuation
        init(continuation: AsyncStream<Data>.Continuation) { self.continuation = continuation }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            continuation.yield(Data(unwrapInboundIn(data).readableBytesView))
        }
        func channelInactive(context: ChannelHandlerContext) { continuation.finish() }
    }
}

@Suite("SftpChannel sobre SshSession (GH-55)", .serialized, .timeLimit(.minutes(1)))
struct SftpOverSshSessionTests {
    @Test func opensSftpSubsystemOnTheSameAuthenticatedConnection() async throws {
        let key = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let ssh = try await MockSSHServer.start(username: "ada", authorizedKey: key.publicKey)
        let session = try await SshSession.connect(
            host: "127.0.0.1", port: ssh.port, username: "ada", privateKey: key,
            hostKeyPolicy: .pinned(ssh.hostKey))
        // El mock hace eco del subsistema: devuelve nuestro INIT en vez de
        // VERSION, prueba de que los bytes viajaron por el canal `sftp`.
        await #expect(throws: SftpError.unexpectedResponse(.initialize)) {
            _ = try await SftpChannel.open(over: session, timeout: .seconds(5))
        }
        #expect(ssh.observed.subsystems == ["sftp"])
        #expect(await session.isConnected)  // misma sesión, sigue viva
        await session.close()
        await ssh.shutdown()
    }

    @Test func lostSessionFailsWithSessionLostWithoutNetwork() async throws {
        let key = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let ssh = try await MockSSHServer.start(username: "ada", authorizedKey: key.publicKey)
        let stream = try await ControlledTCPStream.connect(port: ssh.port)
        let session = try await SshSession.connect(
            over: stream, username: "ada", privateKey: key, hostKeyPolicy: .pinned(ssh.hostKey))
        stream.markLost()
        await waitUntil { session.linkState.isTerminal }
        #expect(session.linkState == .lost(.reconnectExhausted))

        await #expect(throws: SftpError.sessionLost) {
            _ = try await SftpChannel.open(over: session, timeout: .seconds(5))
        }
        #expect(ssh.observed.subsystems.isEmpty)  // no se pidió nada al servidor
        await session.close()
        await stream.close()
        await ssh.shutdown()
    }
}
