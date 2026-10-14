import AppKit
import AuthKit
import ExplorerUI
import GCPClient
import OSLog
import TunnelKit

// GH-65: diagnóstico de conectividad IAP por instancia. Solo cableado: los
// pasos viven en GCPClient (DiagnosticsRunner) y el panel en ExplorerUI; aquí
// el probe WebSocket sobre TunnelKit y la ventana.

enum IapWebSocketProbe {
    /// Conexión de diagnóstico aislada: abre el relay, espera el SID y cierra
    /// (`RelayStream.probe`). No reserva puerto local ni reutiliza túneles.
    static func probe(
        _ target: DiagnosticsTarget, accessToken: @escaping @Sendable () async throws -> String,
        opener: any RelayChannelOpening = NIOWebSocketTransport(), timeout: Duration = .seconds(15)
    ) async -> WebSocketProbeOutcome {
        let endpoint = RelayEndpoint(IapEndpoint(
            project: target.project, zone: target.zone, instance: target.instance, port: target.port))
        let started = ContinuousClock.now
        do {
            try await RelayStream.probe(endpoint: endpoint, opener: opener, accessToken: accessToken, timeout: timeout)
            return .connected(latency: ContinuousClock.now - started)
        } catch let error as TunnelError {
            return classify(error)
        } catch is AuthError {
            return .authRejected  // sin token válido no hay handshake
        } catch {
            return .networkUnreachable("\(type(of: error))")
        }
    }

    /// Exhaustivo: un caso nuevo de `TunnelError` no compila sin clasificar.
    static func classify(_ error: TunnelError) -> WebSocketProbeOutcome {
        switch error {
        case .connectionDenied:
            return .authRejected
        case .backendUnreachable:
            return .backendUnreachable
        case .timeout, .proxyBlocked:
            return .networkUnreachable(error.userMessage)
        case .handshakeFailed(let detail):
            return detail.contains("401") ? .authRejected : .networkUnreachable(error.userMessage)
        case .backendNotFound, .relayClosed, .reconnectExhausted, .protocolViolation, .invalidURL, .portDenied:
            return .protocolError(error.userMessage)
        }
    }
}

/// Ventanas de diagnóstico abiertas (una por instancia).
@MainActor
final class DiagnosticsPanels {
    static let log = Logger(subsystem: "com.iapdesktop.mac", category: "diagnostics")

    private let client: GCPClient
    private let accessToken: @Sendable () async throws -> String
    private var windows: [String: DiagnosticsWindowController] = [:]

    init(client: GCPClient, accessToken: @escaping @Sendable () async throws -> String) {
        self.client = client
        self.accessToken = accessToken
    }

    func show(_ instance: InstanceInfo) {
        let target = instance.os == .windows
            ? DiagnosticsTarget.rdp(project: instance.project, zone: instance.zone, instance: instance.name)
            : DiagnosticsTarget.ssh(project: instance.project, zone: instance.zone, instance: instance.name)
        if let existing = windows[instance.id] {
            existing.showWindow(nil)
            existing.start()
            return
        }
        let accessToken = self.accessToken
        let runner = DiagnosticsRunner(client: client) { await IapWebSocketProbe.probe($0, accessToken: accessToken) }
        let controller = DiagnosticsWindowController(instanceName: instance.name) {
            Self.log.notice("diagnostics started target=\(instance.id, privacy: .public) port=\(target.port, privacy: .public)")
            let report = await runner.run(target)
            // Solo paso + estado: ni tokens ni cuerpos de respuesta (REQ-DIAG-6).
            let summary = report.steps.map { "\($0.kind.rawValue)=\(Self.state($0.result))" }.joined(separator: " ")
            Self.log.notice("diagnostics finished target=\(instance.id, privacy: .public) \(summary, privacy: .public)")
            return report
        }
        windows[instance.id] = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.start()
    }

    private static func state(_ result: DiagnosticStepResult) -> String {
        switch result {
        case .passed: return "passed"
        case .failed: return "failed"
        case .skipped: return "skipped"
        case .notApplicable: return "n/a"
        }
    }
}
