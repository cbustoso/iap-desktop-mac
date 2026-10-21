import Foundation
import TunnelKit

/// Errores tipados del túnel Bastion (REQ-AZ-7, research §9.3). Ningún caso
/// lleva tokens: `message` es el texto de error que devuelve el Bastion.
public enum BastionTunnelError: Error, Sendable, Equatable, CustomStringConvertible {
    /// SKU Basic/Developer o *native client support* desactivado.
    case nativeClientDisabled(sku: String)
    /// El bastionHost no expone `properties.dnsName`.
    case missingDNSName
    /// 401/403 en `/api/tokens` o en el upgrade del WebSocket.
    case unauthorized(message: String?)
    /// 404: VM o Bastion inexistentes (o sesión ya caducada).
    case targetNotFound
    /// Respuesta que no encaja con el protocolo conocido (JSON inesperado,
    /// frame de texto, status de upgrade raro): Azure pudo cambiar la API.
    case protocolChanged(status: Int?)
    /// Error HTTP del servicio no clasificado (5xx, 429…).
    case serviceError(status: Int, message: String?)
    /// El WebSocket se cerró sin Close 1000 (`nil` = corte abrupto).
    case connectionLost(code: Int?)
    case timeout
    /// El proxy HTTP no permite el CONNECT hacia el Bastion.
    case proxyBlocked
    /// Error de red sin respuesta HTTP (DNS, TLS, conexión rechazada).
    case network(String)

    /// Mensaje accionable para la UI.
    public var userMessage: String {
        switch self {
        case .nativeClientDisabled(let sku):
            return "El Bastion (SKU \(sku)) no admite el túnel nativo: hace falta SKU Standard o Premium "
                + "con «Native client support» activado."
        case .missingDNSName:
            return "El Bastion no expone su nombre DNS (properties.dnsName); revisa que esté aprovisionado."
        case .unauthorized(let message):
            return "Azure rechazó el acceso al Bastion o a la VM. Necesitas el rol Reader sobre la VM, "
                + "su NIC y el Bastion." + (message.map { " (\($0))" } ?? "")
        case .targetNotFound:
            return "El Bastion no encuentra la VM o la sesión ya no existe."
        case .protocolChanged(let status):
            return "El Bastion respondió de una forma no reconocida"
                + (status.map { " (HTTP \($0))" } ?? "") + "; puede que Azure haya cambiado el protocolo."
        case .serviceError(let status, let message):
            return "El Bastion devolvió HTTP \(status)." + (message.map { " \($0)" } ?? "")
        case .connectionLost(let code):
            return "Se perdió la conexión con el Bastion" + (code.map { " (código \($0))" } ?? "") + "."
        case .timeout:
            return "El Bastion no respondió a tiempo."
        case .proxyBlocked:
            return "El proxy no permite la conexión WebSocket hacia el Bastion."
        case .network(let what):
            return "No se pudo conectar con el Bastion (\(what))."
        }
    }

    public var description: String { userMessage }

    /// Equivalente para `SshLinkState.lost`, que habla en `TunnelError`.
    public var tunnelError: TunnelError {
        switch self {
        case .unauthorized: return .connectionDenied
        case .targetNotFound: return .backendNotFound
        case .timeout: return .timeout
        case .proxyBlocked: return .proxyBlocked
        case .connectionLost(let code): return .relayClosed(code: code ?? 1006)
        case .protocolChanged: return .protocolViolation("Azure Bastion")
        default: return .handshakeFailed(userMessage)
        }
    }

    /// Texto de error en `{"message": …}` o `{"error": {"message": …}}`, acotado.
    static func message(in body: Data) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let message: String?
            let error: Inner?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
              let text = envelope.message ?? envelope.error?.message, !text.isEmpty
        else { return nil }
        return String(text.prefix(200))
    }
}
