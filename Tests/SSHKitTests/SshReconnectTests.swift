// CBU-42 (T-SSH-6): un shell SSH sobrevive a un corte del túnel IAP.
// `ResumableRelay` imita a IAP: conserva la conexión TCP con el backend
// (MockSSHServer) entre cortes del "WebSocket", confirma lo recibido y, en el
// reconnect, devuelve lo que el cliente no recibió desde su `ack`.
import CryptoKit
import Foundation
import IAPTestSupport
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import SSHKit
@testable import TunnelKit

// MARK: - Relay IAP reanudable en memoria

private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * (3 - $0))) } }
private func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * (7 - $0))) } }

/// "WebSocket" en memoria hacia el cliente. `@unchecked Sendable`: bajo `lock`.
private final class FakeRelaySocket: RelayChannel, @unchecked Sendable {
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var code: Int?
    private var closed = false
    let onClientMessage: @Sendable ([UInt8]) -> Void

    init(onClientMessage: @escaping @Sendable ([UInt8]) -> Void) {
        self.onClientMessage = onClientMessage
        (stream, continuation) = AsyncStream<Data>.makeStream()
    }

    var isAlive: Bool { lock.withLock { !closed && code == nil } }

    func push(_ bytes: [UInt8]) { if isAlive { continuation.yield(Data(bytes)) } }

    func drop(code: Int) {
        lock.withLock { self.code = code }
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        guard isAlive else { throw TunnelError.relayClosed(code: 1006) }
        onClientMessage(Array(data))
    }

    func incoming() -> AsyncStream<Data> { stream }
    func closeCode() async -> Int? { lock.withLock { code } }

    func close() async {
        lock.withLock { closed = true }
        continuation.finish()
    }
}

/// `@unchecked Sendable`: estado bajo `lock`; callbacks de NIO y del cliente.
private final class ResumableRelay: RelayChannelOpening, @unchecked Sendable {
    private let backendPort: Int
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var backend: (any Channel)?
    private var socket: FakeRelaySocket?
    private var toClient: [UInt8] = []  // todo lo enviado por el backend (para rebobinar)
    private var fromClient: UInt64 = 0  // bytes del cliente entregados al backend
    private var reconnectsRefused = false
    private(set) var openedURLs: [URL] = []

    init(backendPort: Int) {
        self.backendPort = backendPort
    }

    var endpoint: RelayEndpoint {
        RelayEndpoint(
            connectURL: { URL(string: "fake://relay/v4/connect")! },
            reconnectURL: { sid, ack in URL(string: "fake://relay/v4/reconnect?sid=\(sid)&ack=\(ack)")! })
    }

    /// Corta el "WebSocket" (como una caída de red); el backend sigue vivo.
    func cut() { lock.withLock { socket }?.drop(code: 1006) }

    /// A partir de ahora los reconnect fallan (red caída de forma persistente).
    func refuseReconnects() { lock.withLock { reconnectsRefused = true } }

    func shutdown() async {
        try? await lock.withLock { backend }?.close()
        try? await group.shutdownGracefully()
    }

    func open(_ url: URL, accessToken: String) async throws -> any RelayChannel {
        lock.withLock { openedURLs.append(url) }
        let socket = FakeRelaySocket { [weak self] message in self?.clientMessage(message) }
        if url.path == "/v4/connect" {
            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { [weak self] channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(BackendReader { self?.backendBytes($0) })
                    }
                }
                .connect(host: "127.0.0.1", port: backendPort).get()
            lock.withLock {
                backend = channel
                self.socket = socket
            }
            socket.push([0, 1] + u32(6) + Array("sid-42".utf8))
            return socket
        }
        // /v4/reconnect?sid&ack
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let ack = UInt64(query.first { $0.name == "ack" }?.value ?? "0") ?? 0
        let (refused, received, replay): (Bool, UInt64, [UInt8]) = lock.withLock {
            if reconnectsRefused { return (true, 0, []) }
            self.socket = socket
            return (false, fromClient, Array(toClient[Int(min(ack, UInt64(toClient.count)))...]))
        }
        if refused {
            socket.drop(code: 1006)
            return socket
        }
        socket.push([0, 2] + u64(received))  // RECONNECT_SUCCESS_ACK
        for chunk in stride(from: 0, to: replay.count, by: 16_384).map({ Array(replay[$0..<min($0 + 16_384, replay.count)]) }) {
            socket.push([0, 4] + u32(UInt32(chunk.count)) + chunk)
        }
        return socket
    }

    private func clientMessage(_ message: [UInt8]) {
        guard message.count >= 6, message[0] == 0, message[1] == 4 else { return }  // solo DATA
        let payload = Array(message[6...])
        let (backend, socket, total): ((any Channel)?, FakeRelaySocket?, UInt64) = lock.withLock {
            fromClient += UInt64(payload.count)
            return (self.backend, self.socket, fromClient)
        }
        guard let backend else { return }
        var buffer = backend.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        backend.writeAndFlush(buffer, promise: nil)
        socket?.push([0, 7] + u64(total))  // ACK
    }

    private func backendBytes(_ bytes: [UInt8]) {
        let socket: FakeRelaySocket? = lock.withLock {
            toClient += bytes
            return self.socket
        }
        socket?.push([0, 4] + u32(UInt32(bytes.count)) + bytes)
    }

    private final class BackendReader: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let onBytes: ([UInt8]) -> Void
        init(onBytes: @escaping ([UInt8]) -> Void) { self.onBytes = onBytes }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            onBytes(Array(unwrapInboundIn(data).readableBytesView))
        }
    }
}

// MARK: - Helpers

private let fast = ReconnectPolicy(
    maxAttempts: 3, initialDelay: .milliseconds(30), multiplier: 2, maxDelay: .milliseconds(200),
    totalTimeout: .seconds(5), handshakeTimeout: .seconds(2))

private func read(until marker: String, from iterator: inout AsyncStream<String>.Iterator) async -> String {
    var text = ""
    while !text.contains(marker), let chunk = await iterator.next() { text += chunk }
    return text
}

private func untilTerminalOr(_ count: Int, _ stream: AsyncStream<SshLinkState>) async -> [SshLinkState] {
    var seen: [SshLinkState] = []
    for await state in stream {
        seen.append(state)
        if state.isTerminal || seen.count >= count { break }
    }
    return seen
}

private struct Rig {
    let ssh: MockSSHServer
    let relay: ResumableRelay
    let session: SshSession

    static func start() async throws -> Rig {
        let key = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let ssh = try await MockSSHServer.start(username: "ada", authorizedKey: key.publicKey)
        let relay = ResumableRelay(backendPort: ssh.port)
        let stream = try await RelayStream.connect(
            endpoint: relay.endpoint, opener: relay, accessToken: { "t" }, reconnectPolicy: fast)
        let session = try await SshSession.connect(
            over: stream, username: "ada", privateKey: key, hostKeyPolicy: .pinned(ssh.hostKey))
        return Rig(ssh: ssh, relay: relay, session: session)
    }

    func shutdown() async {
        await session.close()
        await relay.shutdown()
        await ssh.shutdown()
    }
}

// MARK: - Tests

@Suite("Reconexión SSH vía IAP (CBU-42)", .serialized, .timeLimit(.minutes(1)))
struct SshReconnectTests {
    @Test func shellSurvivesTunnelCutWithSameSessionAndChannel() async throws {
        let rig = try await Rig.start()
        let shell = try await rig.session.openShell()
        var output = shell.output.makeAsyncIterator()
        #expect(await read(until: "mock-shell$ ", from: &output).hasSuffix("mock-shell$ "))
        try await shell.write("antes\n")
        #expect(await read(until: "mock-shell$ ", from: &output).contains("echo:antes"))

        let states = shell.linkStateUpdates()
        rig.relay.cut()
        // Escrito en pleno corte: queda en la cola unacked y se reenvía al reanudar.
        try await shell.write("durante ñ€😀\n")
        #expect(await read(until: "mock-shell$ ", from: &output).contains("echo:durante ñ€😀"))

        let seen = await untilTerminalOr(3, states)
        #expect(seen == [.connected, .reconnecting(attempt: 1), .connected])
        // Misma sesión, mismo canal (la pestaña conserva su identificador).
        #expect(shell.isOpen)
        #expect(await rig.session.isConnected)
        #expect(rig.session.linkState == .connected)
        #expect(rig.relay.openedURLs.last?.query?.contains("sid=sid-42") == true)

        try await shell.write("después\n")
        #expect(await read(until: "mock-shell$ ", from: &output).contains("echo:después"))
        await rig.shutdown()
    }

    @Test func exhaustedRetriesMarkChannelLost() async throws {
        let rig = try await Rig.start()
        let shell = try await rig.session.openShell()
        var output = shell.output.makeAsyncIterator()
        _ = await read(until: "mock-shell$ ", from: &output)

        let states = shell.linkStateUpdates()
        rig.relay.refuseReconnects()
        rig.relay.cut()
        let seen = await untilTerminalOr(10, states)
        #expect(seen.last == .lost(.reconnectExhausted))
        #expect(seen.contains(.reconnecting(attempt: 3)))
        #expect(shell.linkState == .lost(.reconnectExhausted))
        #expect(rig.session.linkState == .lost(.reconnectExhausted))
        // Definitivo: cerrar la sesión no lo convierte en .closed.
        await rig.session.close()
        #expect(rig.session.linkState == .lost(.reconnectExhausted))
        await rig.relay.shutdown()
        await rig.ssh.shutdown()
    }

    @Test func tcpSessionReportsClosedOnClose() async throws {
        let key = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let ssh = try await MockSSHServer.start(username: "ada", authorizedKey: key.publicKey)
        let session = try await SshSession.connect(
            host: "127.0.0.1", port: ssh.port, username: "ada", privateKey: key, hostKeyPolicy: .pinned(ssh.hostKey))
        #expect(session.linkState == .connected)
        await session.close()
        #expect(session.linkState == .closed)
        await ssh.shutdown()
    }

    @Test func linkStatesCarryNoSecrets() {
        let states: [SshLinkState] = [.connected, .reconnecting(attempt: 2), .lost(.reconnectExhausted), .closed]
        for state in states {
            let text = String(describing: state)
            #expect(!text.contains("sid-"))
            #expect(!text.contains("ya29"))
        }
    }
}
