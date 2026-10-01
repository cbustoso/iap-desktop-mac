// CBU-44 (T-TUN-3): RelaySession/RelayStream con un canal relay guionizado.
// Vectores literales (no reutilizan SshRelayFormat) para validar el wire.
import Foundation
import Testing
@testable import TunnelKit

// MARK: - Vectores relay v4

private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * (3 - $0))) } }
private func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * (7 - $0))) } }
private func sidMessage(_ sid: String) -> [UInt8] { [0, 1] + u32(UInt32(sid.utf8.count)) + Array(sid.utf8) }
private func reconnectAck(_ ack: UInt64) -> [UInt8] { [0, 2] + u64(ack) }
private func dataMessage(_ payload: [UInt8]) -> [UInt8] { [0, 4] + u32(UInt32(payload.count)) + payload }
private func ackMessage(_ ack: UInt64) -> [UInt8] { [0, 7] + u64(ack) }

// MARK: - Canal y opener guionizados

/// Lado "servidor" controlado por el test. `@unchecked Sendable`: bajo `lock`.
final class ScriptedChannel: RelayChannel, @unchecked Sendable {
    let url: URL
    let token: String
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var frames: [Data] = []
    private var code: Int?
    private var clientClosed = false

    init(url: URL, token: String) {
        self.url = url
        self.token = token
        (stream, continuation) = AsyncStream<Data>.makeStream()
    }

    var sent: [[UInt8]] { lock.withLock { frames.map(Array.init) } }
    var closedByClient: Bool { lock.withLock { clientClosed } }

    func serverSend(_ bytes: [UInt8]) { continuation.yield(Data(bytes)) }

    func serverClose(code: Int) {
        lock.withLock { self.code = code }
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        try lock.withLock {
            guard !clientClosed, code == nil else { throw TunnelError.relayClosed(code: 1006) }
            frames.append(data)
        }
    }

    func incoming() -> AsyncStream<Data> { stream }
    func closeCode() async -> Int? { lock.withLock { code } }

    func close() async {
        lock.withLock { clientClosed = true }
        continuation.finish()
    }
}

/// Registra cada apertura y deja que el test responda (SID, ACK, cierre…).
final class ScriptedOpener: RelayChannelOpening, @unchecked Sendable {
    typealias Responder = @Sendable (_ attempt: Int, _ channel: ScriptedChannel) -> Void
    private let lock = NSLock()
    private var channels: [ScriptedChannel] = []
    private let responder: Responder

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    var opened: [ScriptedChannel] { lock.withLock { channels } }

    func open(_ url: URL, accessToken: String) async throws -> any RelayChannel {
        let channel = ScriptedChannel(url: url, token: accessToken)
        let attempt = lock.withLock { () -> Int in
            channels.append(channel)
            return channels.count - 1
        }
        responder(attempt, channel)
        return channel
    }
}

/// Token distinto en cada petición, para comprobar que se pide uno fresco.
final class CountingToken: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func next() -> String {
        lock.withLock {
            count += 1
            return "token-\(count)"
        }
    }
}

private let endpoint = RelayEndpoint(
    connectURL: { URL(string: "wss://relay.test/v4/connect")! },
    reconnectURL: { sid, ack in URL(string: "wss://relay.test/v4/reconnect?sid=\(sid)&ack=\(ack)")! })

/// Espera a que `condition` se cumpla (cediendo para que avancen los actores).
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

private func collect(_ stream: AsyncStream<Data>, bytes: Int) async -> Data {
    var all = Data()
    for await chunk in stream {
        all += chunk
        if all.count >= bytes { break }
    }
    return all
}

// MARK: - Tests

@Suite("RelayStream", .timeLimit(.minutes(1)))
struct RelayStreamTests {
    @Test func connectStoresSidAndUsesFreshToken() async throws {
        let tokens = CountingToken()
        let opener = ScriptedOpener { _, channel in channel.serverSend(sidMessage("sid-1")) }
        let stream = try await RelayStream.connect(endpoint: endpoint, opener: opener, accessToken: { tokens.next() })
        #expect(await stream.session.sid == "sid-1")
        #expect(opener.opened.map(\.token) == ["token-1"])
        #expect(opener.opened.first?.url.path == "/v4/connect")
        await stream.close()
    }

    @Test func dataInDataOutAckPiggybackAndTrim() async throws {
        let opener = ScriptedOpener { _, channel in channel.serverSend(sidMessage("s")) }
        let stream = try await RelayStream.connect(endpoint: endpoint, opener: opener, accessToken: { "t" })
        let channel = try #require(opener.opened.first)

        channel.serverSend(dataMessage(Array("hi".utf8)))
        #expect(await collect(stream.incoming(), bytes: 2) == Data("hi".utf8))

        try await stream.send(Data("abc".utf8))
        // El ACK de lo recibido viaja antes del DATA (paridad WriteCoreAsync).
        #expect(channel.sent == [ackMessage(2), dataMessage(Array("abc".utf8))])
        #expect(await stream.unacknowledgedByteCount == 3)

        channel.serverSend(ackMessage(3))
        #expect(await eventually { await stream.unacknowledgedByteCount == 0 })
        await stream.close()
    }

    @Test func largeWritesAreSplitInto16KiBFrames() async throws {
        let opener = ScriptedOpener { _, channel in channel.serverSend(sidMessage("s")) }
        let stream = try await RelayStream.connect(endpoint: endpoint, opener: opener, accessToken: { "t" })
        try await stream.send(Data(repeating: 0x41, count: 40_000))
        let sizes = opener.opened[0].sent.map { Int(u32ToInt(Array($0[2..<6]))) }
        #expect(sizes == [16_384, 16_384, 7_232])
        await stream.close()
    }

    @Test func ackIsForcedAfterOneMiBWithoutWrites() async throws {
        let opener = ScriptedOpener { _, channel in channel.serverSend(sidMessage("s")) }
        let stream = try await RelayStream.connect(endpoint: endpoint, opener: opener, accessToken: { "t" })
        let channel = opener.opened[0]
        let chunk = [UInt8](repeating: 0x42, count: 16_384)
        for _ in 0..<65 { channel.serverSend(dataMessage(chunk)) }  // 1 064 960 B > 1 MiB
        _ = await collect(stream.incoming(), bytes: 65 * 16_384)
        #expect(await eventually { channel.sent.contains { $0.prefix(2) == [0, 7] } })
        await stream.close()
    }

    @Test func abnormalCloseReconnectsWithSidAckAndResendsUnacked() async throws {
        let tokens = CountingToken()
        let opener = ScriptedOpener { attempt, channel in
            if attempt == 0 { channel.serverSend(sidMessage("sid-7")) } else { channel.serverSend(reconnectAck(2)) }
        }
        let stream = try await RelayStream.connect(endpoint: endpoint, opener: opener, accessToken: { tokens.next() })
        let first = opener.opened[0]
        first.serverSend(dataMessage(Array("xyz".utf8)))  // el cliente ha recibido 3 bytes
        _ = await collect(stream.incoming(), bytes: 3)
        try await stream.send(Data("aa".utf8))  // expectedAck 2
        try await stream.send(Data("bbb".utf8))  // expectedAck 5
        first.serverClose(code: 1006)  // caída de red

        #expect(await eventually { opener.opened.count == 2 })
        let second = opener.opened[1]
        #expect(second.url.path == "/v4/reconnect")
        #expect(second.url.query?.contains("sid=sid-7") == true)
        #expect(second.url.query?.contains("ack=3") == true)  // BytesReceived
        #expect(second.token == "token-2")  // token fresco
        // RECONNECT_SUCCESS_ACK(2): "aa" confirmado, solo se reenvía "bbb".
        #expect(await eventually { second.sent.contains(dataMessage(Array("bbb".utf8))) })
        #expect(!second.sent.contains(dataMessage(Array("aa".utf8))))

        second.serverSend(dataMessage(Array("!".utf8)))
        #expect(await collect(stream.incoming(), bytes: 1) == Data("!".utf8))
        #expect(await stream.terminationError == nil)
        await stream.close()
    }

    @Test func reconnectGivesUpAfterTwoAttempts() async throws {
        let opener = ScriptedOpener { attempt, channel in
            if attempt == 0 { channel.serverSend(sidMessage("s")) } else { channel.serverClose(code: 1006) }
        }
        let stream = try await RelayStream.connect(endpoint: endpoint, opener: opener, accessToken: { "t" })
        opener.opened[0].serverClose(code: 1006)
        for await _ in stream.incoming() {}  // termina tras agotar los reintentos
        #expect(await stream.terminationError == .reconnectExhausted)
        #expect(opener.opened.count == 1 + RelaySession.maxReconnects)
    }

    @Test(arguments: [(4033, TunnelError.connectionDenied), (4047, .backendNotFound), (4003, .backendUnreachable)])
    func policyCloseEndsWithoutReconnecting(code: Int, expected: TunnelError) async throws {
        let opener = ScriptedOpener { _, channel in channel.serverSend(sidMessage("s")) }
        let stream = try await RelayStream.connect(endpoint: endpoint, opener: opener, accessToken: { "t" })
        opener.opened[0].serverClose(code: code)
        for await _ in stream.incoming() {}
        #expect(await stream.terminationError == expected)
        #expect(opener.opened.count == 1)
        await #expect(throws: expected) { try await stream.send(Data([1])) }
    }

    @Test func normalCloseEndsCleanly() async throws {
        let opener = ScriptedOpener { _, channel in channel.serverSend(sidMessage("s")) }
        let stream = try await RelayStream.connect(endpoint: endpoint, opener: opener, accessToken: { "t" })
        opener.opened[0].serverClose(code: 1000)
        for await _ in stream.incoming() {}
        #expect(await stream.terminationError == nil)
        #expect(opener.opened.count == 1)
    }

    @Test(arguments: [(4033, TunnelError.connectionDenied), (4047, .backendNotFound)])
    func closeDuringHandshakeIsTyped(code: Int, expected: TunnelError) async {
        let opener = ScriptedOpener { _, channel in channel.serverClose(code: code) }
        await #expect(throws: expected) {
            _ = try await RelayStream.connect(endpoint: endpoint, opener: opener, accessToken: { "t" })
        }
    }

    @Test func handshakeTimeoutIsTyped() async {
        let opener = ScriptedOpener { _, _ in }  // nunca responde
        await #expect(throws: TunnelError.timeout) {
            _ = try await RelayStream.connect(
                endpoint: endpoint, opener: opener, accessToken: { "t" }, timeout: .milliseconds(200))
        }
        #expect(opener.opened.first?.closedByClient == true)
    }

    @Test func descriptionsRedactSidAndToken() async throws {
        let opener = ScriptedOpener { _, channel in channel.serverSend(sidMessage("secret-sid")) }
        let stream = try await RelayStream.connect(
            endpoint: endpoint, opener: opener, accessToken: { "ya29.secret-token" })
        for text in [String(describing: stream), String(describing: stream.session)] {
            #expect(!text.contains("secret-sid"))
            #expect(!text.contains("ya29"))
            #expect(text.contains("<redacted>"))
        }
        await stream.close()
    }
}

private func u32ToInt(_ bytes: [UInt8]) -> UInt32 {
    bytes.reduce(0) { $0 << 8 | UInt32($1) }
}
