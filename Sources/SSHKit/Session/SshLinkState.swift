import Foundation
import TunnelKit

/// Estado del enlace bajo una sesión SSH (CBU-42, T-SSH-6). La reanudación del
/// túnel IAP (`sid&ack` + reenvío) es transparente para SSH: durante
/// `.reconnecting` la sesión y los canales **siguen siendo los mismos**, así
/// que la pestaña conserva su identificador y su contenido.
public enum SshLinkState: Sendable, Equatable {
    case connected
    /// Túnel cortado, reanudando (intento n).
    case reconnecting(attempt: Int)
    /// Perdido definitivamente: la UI debe ofrecer "Reconnect" (nueva sesión).
    case lost(TunnelError)
    /// Cerrado de forma normal.
    case closed

    public var isTerminal: Bool {
        switch self {
        case .lost, .closed: return true
        default: return false
        }
    }
}

extension SshByteStream {
    /// Transportes sin reanudación (p. ej. tests): siempre conectados.
    public func linkStates() async -> AsyncStream<SshLinkState> {
        let (stream, continuation) = AsyncStream<SshLinkState>.makeStream()
        continuation.yield(.connected)
        continuation.finish()
        return stream
    }
}

extension RelayStream {
    /// Estado del túnel IAP traducido a `SshLinkState`.
    public func linkStates() async -> AsyncStream<SshLinkState> {
        let updates = stateUpdates()
        return AsyncStream { continuation in
            let task = Task {
                for await state in updates {
                    switch state {
                    case .connected: continuation.yield(.connected)
                    case .reconnecting(let attempt): continuation.yield(.reconnecting(attempt: attempt))
                    case .lost(let error): continuation.yield(.lost(error))
                    case .closed: continuation.yield(.closed)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// Reparte el estado del enlace a la sesión y a cada canal (varios
/// suscriptores). `.lost` es pegajoso: nada lo sobrescribe después.
/// `@unchecked Sendable`: todo el estado mutable va bajo `lock`.
final class LinkStateHub: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SshLinkState = .connected
    private var subscribers: [UUID: AsyncStream<SshLinkState>.Continuation] = [:]
    private var feeder: Task<Void, Never>?

    var state: SshLinkState { lock.withLock { current } }

    /// Empieza a reenviar los estados del transporte.
    func follow(_ source: AsyncStream<SshLinkState>) {
        let task = Task { [weak self] in
            for await state in source { self?.publish(state) }
        }
        lock.withLock { feeder = task }
    }

    func publish(_ next: SshLinkState) {
        let targets: [AsyncStream<SshLinkState>.Continuation] = lock.withLock {
            if case .lost = current { return [] }  // pegajoso
            guard next != current else { return [] }
            current = next
            let all = Array(subscribers.values)
            if next.isTerminal { subscribers.removeAll() }
            return all
        }
        for continuation in targets {
            continuation.yield(next)
            if next.isTerminal { continuation.finish() }
        }
    }

    func updates() -> AsyncStream<SshLinkState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SshLinkState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let snapshot: SshLinkState = lock.withLock {
            if !current.isTerminal { subscribers[id] = continuation }
            return current
        }
        continuation.yield(snapshot)
        if snapshot.isTerminal {
            continuation.finish()
        } else {
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
            }
        }
        return stream
    }

    func stop() {
        lock.withLock { feeder }?.cancel()
    }
}
