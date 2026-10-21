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
    private var onFinish: (@Sendable () async -> Void)?
    private var closedLocally = false
    private var finished = false
    private var failure: BastionTunnelError?

    private init(socket: any BastionSocket, received: AsyncStream<Data>, onFinish: @escaping @Sendable () async -> Void) {
        self.socket = socket
        self.received = received
        self.onFinish = onFinish
    }

    /// Envuelve un WebSocket ya abierto. `onFinish` se llama una sola vez
    /// cuando el túnel termina (por cualquier lado): libera la sesión Bastion.
    public static func start(
        socket: any BastionSocket, onFinish: @escaping @Sendable () async -> Void = {}
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
        await release?()
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
public struct BastionTunnelFactory: Sendable {
    public let target: BastionTarget
    private let pool: BastionSessionPool
    private let sockets: any BastionSocketOpening

    public init(
        target: BastionTarget,
        sessions: BastionSessionClient = BastionSessionClient(),
        sockets: any BastionSocketOpening = NIOBastionWebSocketTransport(),
        armToken: @escaping BastionSessionPool.ArmTokenProvider
    ) {
        self.target = target
        self.pool = BastionSessionPool(target: target, client: sessions, armToken: armToken)
        self.sockets = sockets
    }

    /// `POST /api/tokens` (encadenado) + WebSocket. Si el WebSocket falla, la
    /// sesión se libera (y se borra si era la última).
    public func openStream() async throws -> BastionTunnelStream {
        let session = try await pool.acquire()
        let socket: any BastionSocket
        do {
            socket = try await sockets.open(.tunnel(dnsName: target.dnsName, session: session))
        } catch {
            await pool.release()
            throw error
        }
        let pool = self.pool
        return await BastionTunnelStream.start(socket: socket) { await pool.release() }
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
