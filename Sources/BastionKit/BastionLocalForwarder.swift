import Foundation
import Network
import RDPBridge
import TunnelKit

/// Listener TCP en `127.0.0.1:{puerto efímero}` que reenvía cada conexión por
/// un `BastionTunnelStream` propio (research §9.3, REQ-AZ-6). Es lo que usa
/// RDP: "Windows App" conecta a `127.0.0.1:{port}` y no sabe del Bastion.
///
/// Solo acepta clientes loopback (mismo filtro que `IapListener`). Las
/// sesiones Bastion se encadenan por conexión y la última se borra con un
/// único `DELETE` al cerrarse la última conexión o al llamar a `stop()`.
public final class BastionLocalForwarder: RdpTunnel {
    public typealias StreamFactory = @Sendable () async throws -> BastionTunnelStream

    public struct Statistics: Sendable, Equatable {
        public var connections = 0
        public var rejectedConnections = 0
        public var failedConnections = 0
        public var bytesUp: UInt64 = 0  // cliente → VM
        public var bytesDown: UInt64 = 0  // VM → cliente
        /// Motivo del último túnel que no se pudo abrir o terminó mal (para la UI).
        public var lastError: BastionTunnelError?
    }

    /// Lectura TCP por bloque: el CLI lee 4096 B y manda un frame por lectura.
    static let readChunk = BastionTunnelStream.maxFrameSize

    public let port: UInt16
    private let listener: NWListener
    private let state: ForwarderState
    private let onStop: @Sendable () async -> Void

    private init(port: UInt16, listener: NWListener, state: ForwarderState, onStop: @escaping @Sendable () async -> Void) {
        self.port = port
        self.listener = listener
        self.state = state
        self.onStop = onStop
    }

    public var localPort: UInt16 { port }

    public var statistics: Statistics { state.statistics }

    /// Reenvía hacia `factory.target`; `stop()` borra la sesión pendiente.
    public static func start(factory: BastionTunnelFactory) async throws -> BastionLocalForwarder {
        try await start(streamFactory: { try await factory.openStream() }, onStop: { await factory.shutdown() })
    }

    public static func start(
        streamFactory: @escaping StreamFactory, onStop: @escaping @Sendable () async -> Void = {}
    ) async throws -> BastionLocalForwarder {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true  // como el CLI (TCP_NODELAY)
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw TunnelError.portDenied
        }
        let state = ForwarderState()
        let queue = DispatchQueue(label: "bastion.forwarder")
        listener.newConnectionHandler = { connection in
            guard IapListener.isClientAllowed(connection.endpoint) else {
                state.update { $0.rejectedConnections += 1 }
                connection.cancel()
                return
            }
            state.update { $0.connections += 1 }
            let task = Task { await forward(connection, factory: streamFactory, state: state, queue: queue) }
            state.track(task, connection: connection)
        }

        let once = OnceFlag()
        let port: UInt16 = try await withCheckedThrowingContinuation { resume in
            listener.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    guard once.claim() else { return }
                    if let port = listener.port?.rawValue {
                        resume.resume(returning: port)
                    } else {
                        resume.resume(throwing: TunnelError.portDenied)
                    }
                case .failed, .cancelled:
                    if once.claim() { resume.resume(throwing: TunnelError.portDenied) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return BastionLocalForwarder(port: port, listener: listener, state: state, onStop: onStop)
    }

    /// Deja de aceptar, corta las conexiones activas (Close 1000 en cada
    /// túnel) y borra la sesión Bastion pendiente.
    public func stop() async {
        listener.cancel()
        for task in state.cancelAll() { await task.value }
        await onStop()
    }

    public func close() async { await stop() }

    // MARK: - Reenvío

    private static func forward(
        _ connection: NWConnection, factory: StreamFactory, state: ForwarderState, queue: DispatchQueue
    ) async {
        connection.start(queue: queue)
        let stream: BastionTunnelStream
        do {
            stream = try await factory()
        } catch {
            state.update {
                $0.failedConnections += 1
                $0.lastError = error as? BastionTunnelError
            }
            connection.cancel()  // sin túnel: el cliente ve el cierre
            return
        }
        await withTaskGroup(of: Void.self) { group in
            // cliente → Bastion
            group.addTask {
                while let data = await receive(connection) {
                    state.update { $0.bytesUp += UInt64(data.count) }
                    do { try await stream.send(data) } catch { break }
                }
                await stream.close()
            }
            // Bastion → cliente
            group.addTask {
                for await data in stream.incoming() {
                    state.update { $0.bytesDown += UInt64(data.count) }
                    guard await send(data, over: connection) else { break }
                }
                connection.cancel()
            }
        }
        await stream.close()
        connection.cancel()
        if let failure = await stream.terminationError {
            state.update { $0.lastError = failure }
        }
    }

    /// Siguiente bloque del cliente; `nil` = fin (EOF, error o cancelado).
    private static func receive(_ connection: NWConnection) async -> Data? {
        while true {
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: readChunk) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete || error != nil {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            guard let chunk else { return nil }
            if !chunk.isEmpty { return chunk }
        }
    }

    private static func send(_ data: Data, over connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }
}

/// Estadísticas y conexiones activas. `@unchecked Sendable`: acceso bajo `lock`.
private final class ForwarderState: @unchecked Sendable {
    private let lock = NSLock()
    private var stats = BastionLocalForwarder.Statistics()
    private var running: [(task: Task<Void, Never>, connection: NWConnection)] = []

    var statistics: BastionLocalForwarder.Statistics { lock.withLock { stats } }

    func update(_ body: (inout BastionLocalForwarder.Statistics) -> Void) {
        lock.withLock { body(&stats) }
    }

    func track(_ task: Task<Void, Never>, connection: NWConnection) {
        lock.withLock { running.append((task, connection)) }
    }

    /// Cancela las conexiones (desbloquea sus `receive`) y devuelve sus tareas.
    func cancelAll() -> [Task<Void, Never>] {
        let entries = lock.withLock { () -> [(task: Task<Void, Never>, connection: NWConnection)] in
            defer { running.removeAll() }
            return running
        }
        entries.forEach { $0.connection.cancel() }
        return entries.map(\.task)
    }
}
