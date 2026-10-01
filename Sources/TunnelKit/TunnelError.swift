import Foundation

/// Enlace de ayuda asociado a un error (paridad `HelpTopics` del original;
/// mismas URLs, sin parámetros de analítica).
public struct HelpTopic: Sendable, Equatable {
    public let title: String
    public let url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }

    public static let grantAccess = HelpTopic(
        title: "Grant access to VMs",
        url: URL(string: "https://googlecloudplatform.github.io/iap-desktop/setup-iap/#grant-access")!)
    public static let createFirewallRule = HelpTopic(
        title: "Create a firewall rule for IAP",
        url: URL(string: "https://googlecloudplatform.github.io/iap-desktop/setup-iap/#create-a-firewall-rule")!)
    public static let proxyConfiguration = HelpTopic(
        title: "Proxy Configuration",
        url: URL(string: "https://googlecloudplatform.github.io/iap-desktop/proxy-configuration/")!)
    public static let tcpForwardingOverview = HelpTopic(
        title: "Overview of Cloud IAP TCP forwarding",
        url: URL(string: "https://cloud.google.com/iap/docs/tcp-forwarding-overview")!)
}

/// Errores tipados de TunnelKit (specs/tunnel/design.md).
///
/// Mapeo (paridad `SshRelaySession`/`IapInstanceTarget`):
/// - handshake HTTP 403 → `connectionDenied`, HTTP 404 → `backendNotFound`;
/// - close 4033 (NOT_AUTHORIZED) → `connectionDenied`;
/// - close 4047/4051 (LOOKUP_FAILED) → `backendNotFound`;
/// - close 4003 (FAILED_TO_CONNECT_TO_BACKEND) → `backendUnreachable`;
/// - reconnect agotado (×2) o SID perdido → `reconnectExhausted`.
public enum TunnelError: Error, Sendable, Equatable {
    case connectionDenied
    case backendNotFound
    /// IAP no llega a la VM (firewall 35.235.240.0/20, puerto cerrado).
    case backendUnreachable
    case relayClosed(code: Int)
    case reconnectExhausted
    case portDenied
    case proxyBlocked
    case invalidURL
    case handshakeFailed(String)
    /// El relay no respondió a tiempo (`ConnectionTimeout`).
    case timeout
    /// El servidor cerró con un mensaje que viola el protocolo relay v4.
    case protocolViolation(String)

    /// Error del relay a partir del close code WebSocket (`nil` = cierre normal).
    public static func fromCloseCode(_ code: Int) -> TunnelError? {
        switch code {
        case 1000: return nil  // NORMAL
        case 4033: return .connectionDenied
        case 4047, 4051: return .backendNotFound
        case 4003: return .backendUnreachable
        case 4001, 4002, 4074: return .reconnectExhausted  // SID_UNKNOWN/IN_USE, FAILED_TO_REWIND
        default: return .relayClosed(code: code)
        }
    }

    /// Mensaje para el usuario (sin secretos: nunca incluye tokens ni SID).
    public var userMessage: String {
        switch self {
        case .connectionDenied:
            return "Acceso denegado por IAP. Comprueba que tienes el rol IAP-secured Tunnel User en la instancia."
        case .backendNotFound:
            return "IAP no encuentra la instancia o la interfaz de red indicada."
        case .backendUnreachable:
            return "IAP no puede conectar con la VM. Comprueba la regla de firewall para 35.235.240.0/20."
        case .relayClosed(let code):
            return "El túnel IAP se cerró inesperadamente (código \(code))."
        case .reconnectExhausted:
            return "Se perdió la conexión con el túnel IAP y no se pudo restablecer."
        case .portDenied:
            return "No se pudo abrir un puerto local para el túnel."
        case .proxyBlocked:
            return "Un proxy bloquea la conexión WebSocket con IAP."
        case .invalidURL:
            return "La dirección del túnel IAP no es válida."
        case .handshakeFailed:
            return "No se pudo establecer el túnel IAP."
        case .timeout:
            return "IAP no respondió a tiempo."
        case .protocolViolation:
            return "IAP respondió con un mensaje inesperado."
        }
    }

    public var helpTopic: HelpTopic? {
        switch self {
        case .connectionDenied: return .grantAccess
        case .backendUnreachable: return .createFirewallRule
        case .proxyBlocked, .handshakeFailed, .timeout: return .proxyConfiguration
        case .backendNotFound, .relayClosed, .reconnectExhausted, .protocolViolation: return .tcpForwardingOverview
        case .portDenied, .invalidURL: return nil
        }
    }
}
