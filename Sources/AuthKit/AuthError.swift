/// Errores tipados de AuthKit (specs/auth/design.md).
import Security

public enum AuthError: Error, Sendable, Equatable {
    case userCancelled
    case loopbackTimeout
    case consentRequired
    case tokenExpired
    case invalidResponse
    case workforceNotSupported
    case keychain(status: OSStatus)
}
