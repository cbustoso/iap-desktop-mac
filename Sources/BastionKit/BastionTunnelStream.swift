import Foundation
import SSHKit

/// Un túnel = un WebSocket = una conexión TCP lógica hacia la VM. Conforma
/// `SshByteStream`, así que `SshSession.connect(over:)` corre SSH/SFTP
/// in-process sin puerto local (REQ-AZ-6).
///
/// Sin framing propio (research §3.3 (4)): cliente → Bastion en frames
/// binarios de ≤ 4096 B (paridad con el CLI); Bastion → cliente, cada frame
/// binario tal cual. Un frame de texto termina el túnel con `.protocolChanged`;
/// un cierre sin Close 1000, con `.connectionLost`.
public actor BastionTunnelStream: SshByteStream {
    public static let maxFrameSize = 4096

    private let socket: any BastionSocket
    private nonisolated let received: AsyncStream<Data>
    private let link = BastionLinkStates()
    private var reader: Task<Void, Never>?
    private var onFinish: (@Sendable (BastionTunnelError?) async -> Void)?
    private var closedLocally = false
    private var finished = false
    private var failure: BastionTunnelError?

    private init(
        socket: any BastionSocket, received: AsyncStream<Data>,
        onFinish: @escaping @Sendable (BastionTunnelError?) async -> Void
    ) {
        self.socket = socket
        self.received = received
        self.onFinish = onFinish
    }

    /// Envuelve un WebSocket ya abierto. `onFinish` se llama una sola vez
    /// cuando el túnel termina (por cualquier lado), con el motivo si fue
    /// anómalo: libera la sesión Bastion.
    public static func start(
        socket: any BastionSocket, onFinish: @escaping @Sendable (BastionTunnelError?) async -> Void = { _ in }
    ) async -> BastionTunnelStream {
        let (received, continuation) = AsyncStream<Data>.makeStream()
        let stream = BastionTunnelStream(socket: socket, received: received, onFinish: onFinish)
        await stream.startReading(into: continuation)
        return stream
    }

    /// Motivo del fin anómalo; `nil` mientras está abierto o si cerró limpio.
    public var terminationError: BastionTunnelError? { failure }

    public var isFinished: Bool { finished }

    // MARK: - SshByteStream

    public func send(_ data: Data) async throws {
        if let failure { throw failure }
        guard !finished, !closedLocally else { throw BastionTunnelError.connectionLost(code: nil) }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: Self.maxFrameSize, limitedBy: data.endIndex) ?? data.endIndex
            do {
                try await socket.send(Data(data[offset..<end]))
            } catch {
                throw failure ?? error
            }
            offset = end
        }
    }

    public nonisolated func incoming() -> AsyncStream<Data> { received }

    /// Close 1000 y espera a que el túnel termine (y a su `onFinish`).
    public func close() async {
        if !closedLocally {
            closedLocally = true
            await socket.close()
        }
        await reader?.value
    }

    public func linkStates() async -> AsyncStream<SshLinkState> { link.subscribe() }

    // MARK: - Lectura

    private func startReading(into continuation: AsyncStream<Data>.Continuation) {
        let socket = self.socket
        reader = Task {
            var failure: BastionTunnelError?
            for await message in socket.inbound() {
                if case .binary(let data) = message {
                    continuation.yield(data)
                } else {
                    failure = .protocolChanged(status: nil)
                    break
                }
            }
            if failure != nil { await socket.close() }
            let code = await socket.closeCode()
            continuation.finish()
            await self.finish(failure: failure, closeCode: code)
        }
    }

    private func finish(failure: BastionTunnelError?, closeCode: Int?) async {
        guard !finished else { return }
        finished = true
        if let failure {
            self.failure = failure
        } else if !closedLocally, closeCode != 1000 {
            self.failure = .connectionLost(code: closeCode)
        }
        link.finish(self.failure)
        let release = onFinish
        onFinish = nil
        await release?(self.failure)
    }
}

/// Estado del enlace para `SshSession` (varios suscriptores). Sin
/// reanudación: `.connected` hasta que el túnel termina en `.closed` o `.lost`.
/// `@unchecked Sendable`: todo el estado mutable va bajo `lock`.
final class BastionLinkStates: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal: SshLinkState?
    private var subscribers: [AsyncStream<SshLinkState>.Continuation] = []

    func subscribe() -> AsyncStream<SshLinkState> {
        let (stream, continuation) = AsyncStream<SshLinkState>.makeStream()
        let terminal = lock.withLock { () -> SshLinkState? in
            if self.terminal == nil { subscribers.append(continuation) }
            return self.terminal
        }
        continuation.yield(.connected)
        if let terminal {
            continuation.yield(terminal)
            continuation.finish()
        }
        return stream
    }

    func finish(_ failure: BastionTunnelError?) {
        let state: SshLinkState = failure.map { .lost($0.tunnelError) } ?? .closed
        let pending = lock.withLock { () -> [AsyncStream<SshLinkState>.Continuation] in
            terminal = state
            defer { subscribers.removeAll() }
            return subscribers
        }
        for continuation in pending {
            continuation.yield(state)
            continuation.finish()
        }
    }
}

/// Abre túneles hacia un mismo destino compartiendo la sesión Bastion
/// (encadenado + un único `DELETE`, ver `BastionSessionPool`).
///
/// GH-95: si el upgrade del WebSocket falla con un error reintentable (p. ej.
/// `websocketToken` ya caducado → 401/403, corte de red), se renueva la
/// sesión con otro `POST` encadenado y se reintenta el WebSocket con backoff.
/// Un túnel ya establecido **no** se reanuda: el protocolo no tiene SID/ACK
/// (research §3.3 (3)), así que si el WebSocket cae el stream termina con
/// `.connectionLost` y la siguiente conexión pide una sesión encadenada nueva.
public struct BastionTunnelFactory: Sendable {
    public let target: BastionTarget
    private let pool: BastionSessionPool
    private let sockets: any BastionSocketOpening
    private let retry: BastionRetryPolicy
    private let telemetry: BastionTelemetry

    public init(
        target: BastionTarget,
        sessions: BastionSessionClient = BastionSessionClient(),
        sockets: any BastionSocketOpening = NIOBastionWebSocketTransport(),
        retry: BastionRetryPolicy = .default,
        telemetry: BastionTelemetry = .oslog,
        invalidateArmToken: @escaping BastionSessionPool.ArmTokenInvalidator = {},
        armToken: @escaping BastionSessionPool.ArmTokenProvider
    ) {
        self.target = target
        self.pool = BastionSessionPool(
            target: target, client: sessions, retry: retry, telemetry: telemetry,
            invalidateArmToken: invalidateArmToken, armToken: armToken)
        self.sockets = sockets
        self.retry = retry
        self.telemetry = telemetry
    }

    /// `POST /api/tokens` (encadenado) + WebSocket, con renovación. Si al final
    /// no hay WebSocket, la sesión se libera (y se borra si era la última).
    public func openStream() async throws -> BastionTunnelStream {
        var attempt = 1
        while true {
            let session = try await pool.acquire()
            let socket: any BastionSocket
            do {
                socket = try await sockets.open(.tunnel(dnsName: target.dnsName, session: session))
            } catch {
                let failure = BastionTunnelError(error)
                telemetry.record(target, .webSocketFailed(attempt: attempt, error: failure))
                guard attempt < retry.maxAttempts, failure.isRetryable, !Task.isCancelled else {
                    await pool.release()
                    throw attempt > 1 ? BastionTunnelError.retriesExhausted(attempts: attempt, last: failure) : failure
                }
                // Sin DELETE: el siguiente POST encadena esta sesión.
                await pool.abandon()
                let delay = retry.delay(after: attempt)
                telemetry.record(target, .retryScheduled(attempt: attempt, delay: delay, reason: failure))
                do {
                    try await retry.sleep(delay)
                } catch {
                    await pool.deleteIfUnused()
                    throw error
                }
                attempt += 1
                continue
            }
            telemetry.record(target, .webSocketOpened(attempt: attempt))
            let pool = self.pool
            let (target, telemetry) = (self.target, self.telemetry)
            return await BastionTunnelStream.start(socket: socket) { failure in
                if let failure { telemetry.record(target, .tunnelLost(failure)) }
                await pool.release()
            }
        }
    }

    /// Conexiones con sesión activa (diagnóstico y tests).
    public var activeSessions: Int {
        get async { await pool.activeCount }
    }

    /// Borra la sesión pendiente aunque queden túneles abiertos (cierre de perfil).
    public func shutdown() async {
        await pool.shutdown()
    }
}
