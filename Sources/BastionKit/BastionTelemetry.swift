import Foundation
import OSLog

// GH-95: telemetría local de errores del túnel Bastion (REQ-AZ-8). Solo
// OSLog en la propia máquina: nada sale a la red. Los eventos son tipados y
// no tienen campos para tokens, URLs del WebSocket ni textos del servidor;
// el nombre de la VM va como `private` (Console lo oculta salvo en debug).

/// Evento del ciclo de vida de una sesión Bastion.
public enum BastionTelemetryEvent: Sendable, Equatable {
    /// `POST /api/tokens` (intento `attempt`, con o sin `token` + `X-Node-Id`).
    case sessionRequested(attempt: Int, chained: Bool)
    case sessionOpened(attempt: Int, chained: Bool)
    case sessionFailed(attempt: Int, error: BastionTunnelError)
    /// Próximo intento tras `delay` (backoff) por `reason`.
    case retryScheduled(attempt: Int, delay: Duration, reason: BastionTunnelError)
    /// 401/403: se pide al proveedor un token ARM nuevo antes de reintentar.
    case armTokenInvalidated
    /// 404 con sesión encadenada: el Bastion ya la olvidó; se pide una nueva sin encadenar.
    case chainDropped
    case webSocketFailed(attempt: Int, error: BastionTunnelError)
    case webSocketOpened(attempt: Int)
    /// El túnel terminó mal (WebSocket caído, frame de texto…).
    case tunnelLost(BastionTunnelError)
    case sessionDeleted(BastionSessionClient.CloseOutcome)
    case sessionDeleteFailed(BastionTunnelError)
}

/// Destino de la telemetría. `oslog` por defecto; los tests inyectan uno en memoria.
public struct BastionTelemetry: Sendable {
    public typealias Sink = @Sendable (_ target: BastionTarget, _ event: BastionTelemetryEvent) -> Void

    private let sink: Sink

    public init(sink: @escaping Sink) {
        self.sink = sink
    }

    public static let oslog = BastionTelemetry { target, event in log(target, event) }
    public static let disabled = BastionTelemetry { _, _ in }

    public func record(_ target: BastionTarget, _ event: BastionTelemetryEvent) {
        sink(target, event)
    }

    private static let logger = Logger(subsystem: "com.iapdesktop.mac", category: "azure.bastion")

    private static func log(_ target: BastionTarget, _ event: BastionTelemetryEvent) {
        let vm = target.vmName
        let port = target.port
        switch event {
        case .sessionRequested(let attempt, let chained):
            logger.debug("bastion post vm=\(vm, privacy: .private) port=\(port, privacy: .public) attempt=\(attempt, privacy: .public) chained=\(chained, privacy: .public)")
        case .sessionOpened(let attempt, let chained):
            logger.notice("bastion session opened vm=\(vm, privacy: .private) attempt=\(attempt, privacy: .public) chained=\(chained, privacy: .public)")
        case .sessionFailed(let attempt, let error):
            logger.error("bastion post failed vm=\(vm, privacy: .private) attempt=\(attempt, privacy: .public) error=\(error.kind, privacy: .public)")
        case .retryScheduled(let attempt, let delay, let reason):
            logger.notice("bastion retry vm=\(vm, privacy: .private) next=\(attempt + 1, privacy: .public) delayMs=\(delay.milliseconds, privacy: .public) reason=\(reason.kind, privacy: .public)")
        case .armTokenInvalidated:
            logger.notice("bastion arm token invalidated vm=\(vm, privacy: .private)")
        case .chainDropped:
            logger.notice("bastion chained session gone, requesting a new one vm=\(vm, privacy: .private)")
        case .webSocketFailed(let attempt, let error):
            logger.error("bastion websocket failed vm=\(vm, privacy: .private) attempt=\(attempt, privacy: .public) error=\(error.kind, privacy: .public)")
        case .webSocketOpened(let attempt):
            logger.debug("bastion websocket opened vm=\(vm, privacy: .private) attempt=\(attempt, privacy: .public)")
        case .tunnelLost(let error):
            logger.error("bastion tunnel lost vm=\(vm, privacy: .private) port=\(port, privacy: .public) error=\(error.kind, privacy: .public)")
        case .sessionDeleted(let outcome):
            logger.notice("bastion session deleted vm=\(vm, privacy: .private) outcome=\(String(describing: outcome), privacy: .public)")
        case .sessionDeleteFailed(let error):
            logger.error("bastion delete failed vm=\(vm, privacy: .private) error=\(error.kind, privacy: .public)")
        }
    }
}

// MARK: - Reintentos

/// GH-95: backoff exponencial con tope para renovar la sesión (re-POST
/// encadenado y, si hace falta, un WebSocket nuevo). `sleep` es inyectable:
/// los tests registran los retardos sin esperar.
public struct BastionRetryPolicy: Sendable {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    /// Intentos totales (1 = sin reintentos).
    public var maxAttempts: Int
    public var initialDelay: Duration
    public var maxDelay: Duration
    public var multiplier: Double
    public var sleep: Sleeper

    public init(
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(500),
        maxDelay: Duration = .seconds(8),
        multiplier: Double = 2,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.sleep = sleep
    }

    public static let `default` = BastionRetryPolicy()
    public static let none = BastionRetryPolicy(maxAttempts: 1)

    /// Espera antes del intento `attempt + 1` (`attempt` empieza en 1).
    public func delay(after attempt: Int) -> Duration {
        let factor = pow(multiplier, Double(max(0, attempt - 1)))
        let delay = initialDelay * factor
        return delay > maxDelay ? maxDelay : delay
    }
}

extension Duration {
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
