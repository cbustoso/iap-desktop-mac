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
}
