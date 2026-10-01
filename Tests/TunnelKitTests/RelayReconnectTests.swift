// CBU-42 (T-SSH-6): reanudación del túnel con backoff, plazo total y estado.
import Foundation
import Testing
@testable import TunnelKit

private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * (3 - $0))) } }
private func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * (7 - $0))) } }
private func sidMessage(_ sid: String) -> [UInt8] { [0, 1] + u32(UInt32(sid.utf8.count)) + Array(sid.utf8) }
private func reconnectAck(_ ack: UInt64) -> [UInt8] { [0, 2] + u64(ack) }
private func dataMessage(_ payload: [UInt8]) -> [UInt8] { [0, 4] + u32(UInt32(payload.count)) + payload }
private func ackMessage(_ ack: UInt64) -> [UInt8] { [0, 7] + u64(ack) }

private let endpoint = RelayEndpoint(
    connectURL: { URL(string: "wss://relay.test/v4/connect")! },
    reconnectURL: { sid, ack in URL(string: "wss://relay.test/v4/reconnect?sid=\(sid)&ack=\(ack)")! })

private let fast = ReconnectPolicy(
    maxAttempts: 3, initialDelay: .milliseconds(20), multiplier: 2, maxDelay: .milliseconds(200),
    totalTimeout: .seconds(5), handshakeTimeout: .seconds(2))

/// Recoge estados hasta uno terminal o hasta reunir `count`.
private func collectStates(_ stream: AsyncStream<RelayState>, until done: @Sendable ([RelayState]) -> Bool) async -> [RelayState] {
    var seen: [RelayState] = []
    for await state in stream {
        seen.append(state)
        if done(seen) { break }
    }
    return seen
}

/// Proveedor de token conmutable (simula un `splice` de AuthKit).
private final class SwitchableToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(_ value: String) { self.value = value }
    func current() -> String { lock.withLock { value } }
    func splice(to new: String) { lock.withLock { value = new } }
}

@Suite("Reanudación del túnel (CBU-42)", .timeLimit(.minutes(1)))
struct RelayReconnectTests {
    @Test func cutResumesOnTheSameStreamAndPublishesStates() async throws {
        let opener = ScriptedOpener { attempt, channel in
            channel.serverSend(attempt == 0 ? sidMessage("s1") : reconnectAck(0))
        }
        let stream = try await RelayStream.connect(
            endpoint: endpoint, opener: opener, accessToken: { "t" }, reconnectPolicy: fast)
        let states = await stream.stateUpdates()
        opener.opened[0].serverClose(code: 1006)

        let seen = await collectStates(states) { $0.count >= 3 }
        #expect(seen == [.connected, .reconnecting(attempt: 1), .connected])
        #expect(await stream.state == .connected)
        // Mismo objeto, mismo SID: quien lo use (SSH) no nota el corte.
        #expect(await stream.session.sid == "s1")
        opener.opened[1].serverSend(dataMessage(Array("sigue".utf8)))
        var incoming = stream.incoming().makeAsyncIterator()
        #expect(await incoming.next() == Data("sigue".utf8))
        await stream.close()
    }

    @Test func backoffThenLostAfterMaxAttempts() async throws {
        let policy = ReconnectPolicy(
            maxAttempts: 3, initialDelay: .milliseconds(100), multiplier: 2, maxDelay: .seconds(1),
            totalTimeout: .seconds(10), handshakeTimeout: .seconds(2))
        let opener = ScriptedOpener { attempt, channel in
            if attempt == 0 { channel.serverSend(sidMessage("s")) } else { channel.serverClose(code: 1006) }
        }
        let stream = try await RelayStream.connect(
            endpoint: endpoint, opener: opener, accessToken: { "t" }, reconnectPolicy: policy)
        let states = await stream.stateUpdates()
        let started = ContinuousClock.now
        opener.opened[0].serverClose(code: 1006)

        let seen = await collectStates(states) { if case .lost = $0.last { return true }; return false }
        let elapsed = ContinuousClock.now - started
        #expect(seen == [
            .connected, .reconnecting(attempt: 1), .reconnecting(attempt: 2), .reconnecting(attempt: 3),
            .lost(.reconnectExhausted),
        ])
        #expect(opener.opened.count == 1 + 3)
        // Backoff: 0 + 100 ms + 200 ms antes de los intentos 1–3.
        #expect(elapsed >= .milliseconds(300))
        #expect(await stream.terminationError == .reconnectExhausted)
    }

    @Test func totalTimeoutBoundsTheRetries() async throws {
        let policy = ReconnectPolicy(
            maxAttempts: 50, initialDelay: .milliseconds(150), multiplier: 1, maxDelay: .milliseconds(150),
            totalTimeout: .milliseconds(500), handshakeTimeout: .milliseconds(200))
        let opener = ScriptedOpener { attempt, channel in
            if attempt == 0 { channel.serverSend(sidMessage("s")) } else { channel.serverClose(code: 1006) }
        }
        let stream = try await RelayStream.connect(
            endpoint: endpoint, opener: opener, accessToken: { "t" }, reconnectPolicy: policy)
        let started = ContinuousClock.now
        opener.opened[0].serverClose(code: 1006)
        for await _ in stream.incoming() {}
        #expect(ContinuousClock.now - started < .seconds(2))  // acotado, no 50 intentos
        #expect(opener.opened.count < 1 + 50)
        if case .lost(.reconnectExhausted) = await stream.state {} else {
            Issue.record("se esperaba lost(reconnectExhausted), hay \(await stream.state)")
        }
    }

    @Test func partialAckResendsOnlyPendingIncludingWritesDuringTheCut() async throws {
        let gate = Gate()
        let opener = ScriptedOpener { attempt, channel in
            if attempt == 0 {
                channel.serverSend(sidMessage("s"))
            } else {
                // El servidor tenía 2 bytes ("aa"); responde cuando el test lo permite.
                Task { await gate.wait(); channel.serverSend(reconnectAck(2)) }
            }
        }
        let stream = try await RelayStream.connect(
            endpoint: endpoint, opener: opener, accessToken: { "t" }, reconnectPolicy: fast)
        try await stream.send(Data("aa".utf8))  // ack 2
        try await stream.send(Data("bbb".utf8))  // ack 5
        opener.opened[0].serverSend(ackMessage(2))
        #expect(await eventually { await stream.unacknowledgedByteCount == 3 })
        opener.opened[0].serverClose(code: 1006)

        #expect(await eventually { opener.opened.count == 2 })
        try await stream.send(Data("cc".utf8))  // escrito durante la reanudación
        await gate.open()

        let second = opener.opened[1]
        #expect(await eventually {
            second.sent.contains(dataMessage(Array("bbb".utf8))) && second.sent.contains(dataMessage(Array("cc".utf8)))
        })
        #expect(!second.sent.contains(dataMessage(Array("aa".utf8))))  // ya confirmado
        await stream.close()
    }

    @Test func spliceDuringSessionDoesNotInterruptAndAppliesOnResume() async throws {
        let token = SwitchableToken("token-cuenta-A")
        let opener = ScriptedOpener { attempt, channel in
            channel.serverSend(attempt == 0 ? sidMessage("s") : reconnectAck(0))
        }
        let stream = try await RelayStream.connect(
            endpoint: endpoint, opener: opener, accessToken: { token.current() }, reconnectPolicy: fast)
        token.splice(to: "token-cuenta-B")  // AuthKit re-autoriza en mitad de la sesión

        // El canal activo no se toca: sigue enviando por el mismo socket.
        try await stream.send(Data("x".utf8))
        #expect(opener.opened.count == 1)
        #expect(opener.opened[0].sent.contains(dataMessage([0x78])))
        #expect(await stream.state == .connected)

        // Solo una reanudación futura usa la credencial nueva.
        opener.opened[0].serverClose(code: 1006)
        #expect(await eventually { opener.opened.count == 2 })
        #expect(opener.opened[1].token == "token-cuenta-B")
        await stream.close()
    }

    @Test func lostIsStickyAfterClose() async throws {
        let opener = ScriptedOpener { _, channel in channel.serverSend(sidMessage("s")) }
        let stream = try await RelayStream.connect(
            endpoint: endpoint, opener: opener, accessToken: { "t" }, reconnectPolicy: fast)
        opener.opened[0].serverClose(code: 4033)  // política: sin reintentos
        for await _ in stream.incoming() {}
        await stream.close()
        #expect(await stream.state == .lost(.connectionDenied))
    }

    @Test func backoffDelaysAreExponentialAndCapped() {
        let policy = ReconnectPolicy(initialDelay: .milliseconds(500), multiplier: 2, maxDelay: .seconds(1))
        #expect(policy.delay(beforeAttempt: 1) == .zero)
        #expect(policy.delay(beforeAttempt: 2) == .milliseconds(500))
        #expect(policy.delay(beforeAttempt: 3) == .seconds(1))
        #expect(policy.delay(beforeAttempt: 4) == .seconds(1))  // tope
    }
}

/// Barrera simple para ordenar eventos en el test.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
