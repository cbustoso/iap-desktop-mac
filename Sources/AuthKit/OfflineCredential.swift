import Foundation

/// Emisores de identidad soportados.
public enum OidcIssuer: String, Sendable, Codable {
    case gaia = "https://oauth2.googleapis.com/"
    case sts = "https://sts.googleapis.com/"
}

/// Credencial offline persistida (solo vive en Keychain, nunca en disco plano).
/// Los tokens se redactan en cualquier representación de depurado (REQ-AUTH-6).
public struct OfflineCredential: Sendable, Codable, Equatable {
    public var issuer: OidcIssuer
    public var email: String
    public var refreshToken: String
    public var idToken: String
    public var scopes: [String]
    public var issuedAt: Date

    public init(
        issuer: OidcIssuer,
        email: String,
        refreshToken: String,
        idToken: String,
        scopes: [String],
        issuedAt: Date = Date()
    ) {
        self.issuer = issuer
        self.email = email
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.scopes = scopes
        self.issuedAt = issuedAt
    }
}

extension OfflineCredential: CustomDebugStringConvertible {
    public var debugDescription: String {
        "OfflineCredential(issuer: \(issuer.rawValue), email: \(email), scopes: \(scopes), issuedAt: \(issuedAt), tokens: <redacted>)"
    }
}
