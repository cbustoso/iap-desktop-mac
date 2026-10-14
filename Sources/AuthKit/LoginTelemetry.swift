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

/// Identifica el build en cada línea de log (CBU-28e): descarta builds viejos
/// y distingue el `.app` del binario SwiftPM suelto (sin Info.plist).
public enum BuildInfo {
    /// `build=0.1/app` o `build=dev/bare`.
    public static func describe(version: String?, isAppBundle: Bool) -> String {
        let trimmed = version?.trimmingCharacters(in: .whitespaces)
        let label = (trimmed?.isEmpty == false) ? trimmed! : "dev"
        return "build=\(label)/\(isAppBundle ? "app" : "bare")"
    }

    /// Build del proceso actual.
    public static var current: String {
        describe(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            isAppBundle: Bundle.main.bundleURL.pathExtension == "app")
    }
}

extension LogRedaction {
    /// Primeros 8 caracteres del client ID (el número de proyecto: no es
    /// secreto). Nunca el ID completo ni el secret.
    public static func clientIDPrefix(_ clientID: String) -> String {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<empty>" }
        return String(trimmed.prefix(8)) + "…"
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
    case tokenRefreshRejected(status: Int, oauthError: String?, description: String?)
    /// El refresh token guardado es de otro cliente OAuth (`unauthorized_client`):
    /// hay que volver a iniciar sesión con el cliente actual.
    case sessionFromOtherClient
    /// Sin client ID configurado (GH-80: el bundle no lo embebe): no se llamó a Google.
    case clientNotConfigured
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
            case .tokenEndpoint(let status, let oauthError, let description):
                switch oauthError {
                case "invalid_grant": self = .sessionRejected
                case "unauthorized_client": self = .sessionFromOtherClient
                default: self = .tokenRefreshRejected(status: status, oauthError: oauthError, description: description)
                }
            case .clientNotConfigured:
                self = .clientNotConfigured
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
        case .tokenRefreshRejected(let status, let oauthError, let description):
            return "cause=token_refresh http=\(status) oauth_error=\(oauthError ?? "-") desc=\(description ?? "-")"
        case .sessionFromOtherClient: return "cause=other_client oauth_error=unauthorized_client"
        case .clientNotConfigured: return "cause=no_client_id"
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
        case .tokenRefreshRejected(_, let oauthError, _):
            return "No se pudo renovar la sesión (\(oauthError ?? "error OAuth")): vuelve a iniciar sesión."
        case .sessionFromOtherClient:
            return "La sesión guardada es de otro cliente OAuth: vuelve a iniciar sesión."
        case .clientNotConfigured:
            return "Sin client OAuth: define GOOGLE_OAUTH_CLIENT_ID/SECRET o ~/.config/iap-desktop-mac/secrets.env (docs/usage.md)."
        case .unknown: return "No se pudieron cargar los proyectos."
        }
    }
}
