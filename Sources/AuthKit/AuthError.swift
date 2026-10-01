/// Errores tipados de AuthKit (specs/auth/design.md).
///
/// `consentRequired` y `workforceNotSupported` se producen en T-AUTH-4
/// (login UI) y M4 (WIF); se declaran aquí para fijar el vocabulario.
import Security

public enum AuthError: Error, Sendable, Equatable {
    case userCancelled
    case loopbackTimeout
    case consentRequired
    case tokenExpired
    case invalidResponse
    case workforceNotSupported
    case keychain(status: OSStatus)
    case network(String)
    /// `/token` respondió con error HTTP. `error`/`description` son los campos
    /// OAuth del cuerpo JSON (`invalid_grant`, `invalid_client`…): no contienen
    /// secretos y se muestran tal cual para poder diagnosticar.
    case tokenEndpoint(status: Int, error: String?, description: String?)
    /// `/token` respondió 200 pero el cuerpo no es un token válido.
    case malformedTokenResponse
    /// Sin `id_token`: no se concedió `openid`/`email`, no hay identidad.
    case missingIDToken
    /// `id_token` sin claim `email` (o ilegible).
    case idTokenWithoutEmail
    /// Sin `refresh_token`: no se puede guardar la sesión offline.
    case missingRefreshToken
    /// Este build no tiene client ID (p. ej. binario SwiftPM sin Info.plist):
    /// se falla en local en vez de mandar `client_id` vacío a Google (CBU-28e).
    case clientNotConfigured
}

/// Etapas del login installed-app, en orden. El texto es el de la ventana
/// Sign In; el `rawValue` se usa en la traza (OSLog).
public enum LoginStage: String, Sendable, CaseIterable {
    case preparing
    case waitingForBrowser
    case validatingCallback
    case exchangingCode
    case verifyingIdentity
    case savingCredentials

    public var statusText: String {
        switch self {
        case .preparing: return "Preparing sign-in…"
        case .waitingForBrowser: return "Waiting for browser… Complete the sign-in in Google."
        case .validatingCallback: return "Validating Google's response…"
        case .exchangingCode: return "Exchanging authorization code…"
        case .verifyingIdentity: return "Verifying your identity…"
        case .savingCredentials: return "Saving credentials…"
        }
    }
}

/// Mensaje específico para la ventana Sign In a partir del error y la etapa
/// en la que ocurrió. Nunca incluye códigos de autorización ni tokens.
public enum LoginFailure {
    public static func message(for error: any Error, at stage: LoginStage) -> String {
        guard let error = error as? AuthError else {
            return "Sign-in failed during \"\(stage.rawValue)\" (\(type(of: error)))."
        }
        switch error {
        case .userCancelled:
            return "Sign-in was cancelled."
        case .consentRequired:
            return "Google requires additional consent."
        case .loopbackTimeout:
            return "No response arrived from the browser within 120 s. "
                + "Check that no local proxy or firewall blocks 127.0.0.1, then try again."
        case .tokenEndpoint(let status, let oauthError, let description):
            let detail = [oauthError, description].compactMap { $0 }.joined(separator: ": ")
            let base = "Google rejected the sign-in (HTTP \(status)\(detail.isEmpty ? "" : " — \(detail)"))."
            return base + hint(for: oauthError).map { " \($0)" }.orEmpty
        case .network(let description):
            return "Network error while contacting Google: \(description)"
        case .malformedTokenResponse:
            return "Google returned an unreadable token response."
        case .missingIDToken:
            return "Google did not return an ID token (the openid/email scope was not granted), "
                + "so the account cannot be identified."
        case .idTokenWithoutEmail:
            return "Google's ID token does not include an email address."
        case .missingRefreshToken:
            return "Google did not return a refresh token, so the session cannot be kept."
        case .keychain(let status):
            return "Could not save the credentials to the Keychain (OSStatus \(status))."
        case .invalidResponse:
            switch stage {
            case .waitingForBrowser, .validatingCallback:
                return "The browser returned an unexpected response (no authorization code)."
            case .exchangingCode:
                return "Google returned an unexpected response to the code exchange."
            default:
                return "Unexpected response during \"\(stage.rawValue)\"."
            }
        case .tokenExpired:
            return "The session expired. Please sign in again."
        case .workforceNotSupported:
            return "Workforce identity sign-in is not supported yet."
        case .clientNotConfigured:
            return "This build has no OAuth client ID. Run the IAPDesktopMac.app bundle, "
                + "or set GOOGLE_OAUTH_CLIENT_ID for development builds."
        }
    }

    /// Causa habitual de cada error OAuth de `/token` (RFC 6749 §5.2).
    static func hint(for oauthError: String?) -> String? {
        switch oauthError {
        case "invalid_grant":
            return "The authorization code was rejected (expired, already used, or PKCE/redirect mismatch)."
        case "invalid_client", "unauthorized_client":
            return "The OAuth client is not valid for this app (it must be a Desktop app client)."
        case "redirect_uri_mismatch":
            return "The loopback redirect URI is not allowed for this OAuth client."
        case "access_denied":
            return "Access was denied."
        case "invalid_request":
            return "The request is incomplete for this OAuth client (see Google's description)."
        default:
            return nil
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
