import Foundation
import Network

public enum LocalListenerError: Error, Equatable, CustomStringConvertible {
    case invalidPort(Int)
    case failed(String)
    case cancelled

    public var description: String {
        switch self {
        case .invalidPort(let port): return "Puerto local inválido: \(port)."
        case .failed(let why): return "No se pudo escuchar en 127.0.0.1: \(why)."
        case .cancelled: return "Listener cancelado."
        }
    }
}

/// (f) Listener TCP en 127.0.0.1 (solo loopback, nunca 0.0.0.0) con
/// Network.framework. Cada conexión aceptada se entrega ya arrancada.
public final class LocalListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "bastion-spike.listener")

    public init(port: Int) throws {
        guard (0...65_535).contains(port) else { throw LocalListenerError.invalidPort(port) }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true  // como el CLI (TCP_NODELAY)
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: port == 0 ? .any : NWEndpoint.Port(rawValue: UInt16(port))!
        )
        parameters.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw LocalListenerError.failed(String(describing: error))
        }
    }

    /// Arranca y espera a `.ready`. Devuelve el puerto real (útil con 0).
    public func start(onConnection: @escaping @Sendable (NWConnectionStream) -> Void) async throws -> Int {
        listener.newConnectionHandler = { [queue] connection in
            onConnection(NWConnectionStream(connection: connection, queue: queue))
        }
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: LocalListenerError.failed(String(describing: error))) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: LocalListenerError.cancelled) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
    }
}

/// `NWConnection` como `LocalStream`.
public final class NWConnectionStream: LocalStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        connection.start(queue: queue)
    }

    public var remoteDescription: String { String(describing: connection.endpoint) }

    public func receive(maximum: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error, !isComplete {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    public func close() async {
        connection.cancel()
    }
}
