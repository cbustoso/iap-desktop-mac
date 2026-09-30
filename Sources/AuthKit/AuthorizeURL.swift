import Foundation

/// Builds and validates Google OAuth installed-app authorization requests.
public struct AuthorizeURL: Sendable {
    public static let cloudScope = "https://www.googleapis.com/auth/cloud-platform"
    public static let emailScope = "https://www.googleapis.com/auth/userinfo.email"

    public let clientID: String
    public let scopes: [String]

    public init(clientID: String, scopes: [String] = [Self.cloudScope]) {
        self.clientID = clientID
        self.scopes = scopes
    }

    /// Returns the authorization URL and the random state that must be checked
    /// when Google redirects back to the app.
    public func build(
        redirectURI: URL,
        pkce: PKCE,
        loginHint: String? = nil
    ) -> (url: URL, state: String) {
        let state = Self.randomState()
        return (
            makeURL(
                redirectURI: redirectURI,
                codeChallenge: pkce.challenge,
                state: state,
                loginHint: loginHint),
            state
        )
    }

    /// Deterministic form used when the caller already owns a state value.
    public func makeURL(
        redirectURI: URL,
        codeChallenge: String,
        state: String,
        loginHint: String? = nil
    ) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint, !loginHint.isEmpty {
            items.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        components.queryItems = items
        return components.url!
    }

    /// Validates OAuth state and returns the authorization code.
    public func validate(callback: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw AuthError.invalidResponse
        }
        let values = Dictionary(
            components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
            uniquingKeysWith: { first, _ in first })
        if values["error"] != nil || values["state"] != expectedState {
            throw AuthError.userCancelled
        }
        guard let code = values["code"], !code.isEmpty else {
            throw AuthError.invalidResponse
        }
        return code
    }

    private static func randomState() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncoded()
    }
}
