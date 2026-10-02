import Foundation
import TunnelKit

extension HelpTopic {
    /// Paridad `HelpTopics.ManagingOsLogin`.
    public static let managingOsLogin = HelpTopic(
        title: "Managing OS Login",
        url: URL(string: "https://cloud.google.com/compute/docs/oslogin/manage-oslogin-in-an-org")!)
}

/// Error de conexión listo para la UI: mensaje sin secretos + ayuda opcional.
public struct ConnectionFailure: Sendable, Equatable {
    public let message: String
    public let helpTopic: HelpTopic?

    public init(message: String, helpTopic: HelpTopic?) {
        self.message = message
        self.helpTopic = helpTopic
    }

    /// Traduce cualquier error de la cadena túnel → credencial → SSH.
    public init(_ error: any Error) {
        switch error {
        case let tunnel as TunnelError:
            self.init(message: tunnel.userMessage, helpTopic: tunnel.helpTopic)
        case let auth as SshAuthError:
            self.init(message: Self.message(for: auth), helpTopic: Self.helpTopic(for: auth))
        case SSHTransportError.authenticationFailed:
            self.init(
                message: "La VM rechazó la llave SSH. Puede que la autorización aún no se haya propagado.",
                helpTopic: .managingOsLogin)
        case HostKeyVerificationError.changed(let change):
            self.init(message: change.userMessage, helpTopic: nil)
        case HostKeyVerificationError.storeUnavailable:
            self.init(
                message: "No se pudo leer ni guardar la identidad de la VM en el llavero. Conexión bloqueada.",
                helpTopic: nil)
        case SSHTransportError.hostKeyRejected:
            self.init(
                message: "La identidad (host key) de la VM cambió desde la última conexión. Conexión bloqueada.",
                helpTopic: nil)
        case SshSessionError.timeout:
            self.init(message: "La VM no completó el inicio de sesión SSH a tiempo.", helpTopic: .createFirewallRule)
        case SshConnectError.unsupportedKeyAlgorithm:
            self.init(message: "El tipo de llave configurado no está soportado.", helpTopic: nil)
        default:
            self.init(message: "No se pudo abrir la sesión SSH.", helpTopic: .tcpForwardingOverview)
        }
    }

    private static func message(for error: SshAuthError) -> String {
        switch error {
        case .osLoginSecurityKeyNotSupported:
            return "La instancia exige OS Login con llave de seguridad, que aún no está soportado."
        case .osLoginRequired:
            return "La instancia exige OS Login, pero la política no lo permite."
        default:
            return "No se pudo autorizar la llave SSH en la instancia."
        }
    }

    private static func helpTopic(for error: SshAuthError) -> HelpTopic? {
        .managingOsLogin
    }
}
