import Foundation
import Network

/// Listener TCP en `127.0.0.1:{puerto efímero}` que reenvía cada conexión
/// por un `RelayStream` propio (paridad `IapListener`/`SshRelayListener`):
/// un cliente local (SSH, RDP…) habla con la VM como si fuera local.
///
/// Solo acepta clientes de loopback (`isClientAllowed`). Las estadísticas no
/// incluyen contenido.
public final class IapListener: Sendable {
    /// Abre un `RelayStream` nuevo por conexión entrante.
    public typealias StreamFactory = @Sendable () async throws -> RelayStream

    public struct Statistics: Sendable, Equatable {
        public var connections = 0
        public var rejectedConnections = 0
        public var bytesUp: UInt64 = 0  // cliente → VM
        public var bytesDown: UInt64 = 0  // VM → cliente
    }

    public let port: UInt16
    private let listener: NWListener
    private let state: ListenerState

    private init(port: UInt16, listener: NWListener, state: ListenerState) {
        self.port = port
        self.listener = listener
        self.state = state
    }

    public var statistics: Statistics { state.statistics }

    public static func start(streamFactory: @escaping StreamFactory) async throws -> IapListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw TunnelError.portDenied
        }
        let state = ListenerState()
        let queue = DispatchQueue(label: "iap.listener")
        listener.newConnectionHandler = { connection in
            guard isClientAllowed(connection.endpoint) else {
                state.update { $0.rejectedConnections += 1 }
                connection.cancel()
                return
            }
            state.update { $0.connections += 1 }
            let task = Task { await forward(connection, factory: streamFactory, state: state, queue: queue) }
            state.track(task)
        }

        let once = ResumeOnce()
        let port: UInt16 = try await withCheckedThrowingContinuation { resume in
            listener.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    if once.claim() {
                        if let port = listener.port?.rawValue {
                            resume.resume(returning: port)
                        } else {
                            resume.resume(throwing: TunnelError.portDenied)
                        }
                    }
                case .failed, .cancelled:
                    if once.claim() { resume.resume(throwing: TunnelError.portDenied) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return IapListener(port: port, listener: listener, state: state)
    }

    /// Deja de aceptar conexiones y cierra las activas.
    public func stop() async {
        listener.cancel()
        state.cancelAll()
    }

    /// Solo loopback (IPv4/IPv6): nadie de la red local usa el túnel ajeno.
    /// Público: `BastionLocalForwarder` (GH-94) aplica el mismo filtro.
    public static func isClientAllowed(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address): return address == .loopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    // MARK: - Reenvío

    private static func forward(
        _ connection: NWConnection, factory: StreamFactory, state: ListenerState, queue: DispatchQueue
    ) async {
        connection.start(queue: queue)
        let stream: RelayStream
        do {
            stream = try await factory()
        } catch {
            connection.cancel()  // sin túnel: el cliente ve el cierre
            return
        }
        await withTaskGroup(of: Void.self) { group in
            // cliente → relay
            group.addTask {
                while let data = await receive(connection), !data.isEmpty {
                    state.update { $0.bytesUp += UInt64(data.count) }
                    do { try await stream.send(data) } catch { break }
                }
                await stream.close()
            }
            // relay → cliente
            group.addTask {
                for await data in stream.incoming() {
                    state.update { $0.bytesDown += UInt64(data.count) }
                    guard await send(data, over: connection) else { break }
                }
                connection.cancel()
            }
        }
        connection.cancel()
    }

    /// Siguiente bloque del cliente; `nil` o vacío = fin.
    private static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
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

/// Estadísticas y tareas activas. `@unchecked Sendable`: acceso bajo `lock`.
private final class ListenerState: @unchecked Sendable {
    private let lock = NSLock()
    private var stats = IapListener.Statistics()
    private var tasks: [Task<Void, Never>] = []

    var statistics: IapListener.Statistics { lock.withLock { stats } }

    func update(_ body: (inout IapListener.Statistics) -> Void) {
        lock.withLock { body(&stats) }
    }

    func track(_ task: Task<Void, Never>) {
        lock.withLock { tasks.append(task) }
    }

    func cancelAll() {
        let running = lock.withLock { () -> [Task<Void, Never>] in
            defer { tasks.removeAll() }
            return tasks
        }
        running.forEach { $0.cancel() }
    }
}
