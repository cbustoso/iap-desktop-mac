import Foundation

/// Redacción para logs (REQ-AUTH-6): nunca emails completos, tokens ni codes.
public enum LogRedaction {
    /// `ada@example.com` → `@example.com`. Sin `@` válido → `<redacted>`.
    public static func emailDomain(_ email: String) -> String {
        guard let at = email.lastIndex(of: "@"), email.index(after: at) < email.endIndex else {
            return "<redacted>"
        }
        let domain = email[email.index(after: at)...]
        guard !domain.contains("@"), !domain.contains(" ") else { return "<redacted>" }
        return "@" + domain
    }
}

/// Causa de un fallo de la auto-carga de proyectos (o de un refresh de
/// token), a partir de datos primitivos para no acoplar AuthKit a GCPClient.
public enum AutoLoadFailure: Sendable, Equatable {
    /// No hay sesión (o caducó sin refresh posible).
    case notSignedIn
    /// Google rechazó las credenciales: HTTP 401 o refresh `invalid_grant`.
    case sessionRejected
    /// HTTP 403: falta el permiso IAM para listar proyectos/instancias.
    case permissionDenied
    /// La API necesaria no está habilitada (`SERVICE_DISABLED`): p. ej.
    /// Cloud Resource Manager apagado en el proyecto.
    case apiNotEnabled
    /// Sin red / DNS / TLS hacia Google.
    case network(String)
    /// Otro error HTTP de la API.
    case server(status: Int)
    /// `/token` rechazó el refresh con otro error OAuth (p. ej.
    /// `invalid_request` sin client_secret, `invalid_client`): se conserva el
    /// código OAuth, que no es secreto, para poder diagnosticar.
    case tokenRefreshRejected(status: Int, oauthError: String?)
    /// Otro tipo de error (solo se conserva el nombre del tipo).
    case unknown(String)

    /// - Parameters:
    ///   - httpStatus: estado HTTP de la API de Google, si lo hubo.
    ///   - reason: motivo de la API (`SERVICE_DISABLED`, …), si lo hubo.
    ///   - urlErrorCode: código `URLError` de un fallo de transporte.
    ///   - authError: error de AuthKit (token/refresh), si lo hubo.
    ///   - typeName: tipo del error original, para el caso desconocido.
    public init(httpStatus: Int?, reason: String? = nil, urlErrorCode: Int?, authError: AuthError?, typeName: String) {
        if let authError {
            switch authError {
            case .tokenExpired, .userCancelled:
                self = .notSignedIn
            case .tokenEndpoint(let status, let oauthError, _):
                self = oauthError == "invalid_grant"
                    ? .sessionRejected
                    : .tokenRefreshRejected(status: status, oauthError: oauthError)
            case .network(let description):
                self = .network(description)
            default:
                self = .unknown(String(describing: authError))
            }
        } else if let httpStatus {
            switch httpStatus {
            case 401: self = .sessionRejected
            case 403 where reason == "SERVICE_DISABLED": self = .apiNotEnabled
            case 403: self = .permissionDenied
            default: self = .server(status: httpStatus)
            }
        } else if let urlErrorCode {
            self = .network("URLError \(urlErrorCode)")
        } else {
            self = .unknown(typeName)
        }
    }

    /// Fragmento para OSLog (público: sin secretos).
    public var logCause: String {
        switch self {
        case .notSignedIn: return "cause=notSignedIn"
        case .sessionRejected: return "cause=unauthorized http=401"
        case .permissionDenied: return "cause=iam http=403"
        case .apiNotEnabled: return "cause=api-disabled http=403"
        case .network(let description): return "cause=network detail=\(description)"
        case .server(let status): return "cause=http http=\(status)"
        case .tokenRefreshRejected(let status, let oauthError):
            return "cause=token_refresh http=\(status) oauth_error=\(oauthError ?? "-")"
        case .unknown(let type): return "cause=unknown type=\(type)"
        }
    }

    /// Nota para la status bar (el árbol conserva el último snapshot o el mock).
    public var userNote: String {
        switch self {
        case .notSignedIn: return "Sin sesión: inicia sesión para cargar tus proyectos."
        case .sessionRejected: return "Google rechazó la sesión (401): vuelve a iniciar sesión."
        case .permissionDenied: return "Sin permiso IAM para listar proyectos (403)."
        case .apiNotEnabled: return "API sin habilitar (403): `gcloud services enable cloudresourcemanager.googleapis.com` o usa Add project."
        case .network: return "Sin conexión con Google: no se pudieron cargar los proyectos."
        case .server(let status): return "Google respondió \(status) al cargar los proyectos."
        case .tokenRefreshRejected(_, let oauthError):
            return "No se pudo renovar la sesión (\(oauthError ?? "error OAuth")): vuelve a iniciar sesión."
        case .unknown: return "No se pudieron cargar los proyectos."
        }
    }
}
