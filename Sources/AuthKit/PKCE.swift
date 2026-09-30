import CryptoKit
import Foundation

/// PKCE S256 (RFC 7636) para el flujo installed-app (REQ-AUTH-1).
public struct PKCE: Sendable, Equatable {
    /// 43–128 chars: 32 bytes aleatorios en base64url sin padding (43 chars).
    public var verifier: String
    public var challenge: String
    public var method = "S256"

    public init() {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        self.verifier = Data(bytes).base64URLEncoded()
        self.challenge = Self.challenge(for: self.verifier)
    }

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

extension Data {
    /// Base64url sin padding (RFC 4648 §5).
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
