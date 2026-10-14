// GH-67 (T-AUTH-7): login de Workforce Identity Federation por el auth portal
// (`auth.cloud.google/authorize` + `provider_name`) con PKCE y loopback,
// canje en STS e IntrospectToken para saber quién es (no hay id_token ni email).
import Foundation

/// URL del auth portal y validación del callback.
public struct AuthPortalCodeFlow: Sendable {
    public static let authorizeEndpoint = URL(string: "https://auth.cloud.google/authorize")!
    /// Workforce no emite id_token: basta `cloud-platform`.
    public static let defaultScopes = [AuthorizeURL.cloudScope]

    public let provider: WorkforcePoolProviderLocator
    public let clientID: String
    public let scopes: [String]

    public init(provider: WorkforcePoolProviderLocator, clientID: String, scopes: [String] = Self.defaultScopes) {
        self.provider = provider
        self.clientID = clientID
        self.scopes = scopes
    }

    public func makeURL(redirectURI: URL, codeChallenge: String, state: String) -> URL {
        var components = URLComponents(url: Self.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "provider_name", value: provider.resourceName),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// URL + `state` aleatorio que hay que comprobar en el callback.
    public func build(redirectURI: URL, pkce: PKCE) -> (url: URL, state: String) {
        let state = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncoded()
        return (makeURL(redirectURI: redirectURI, codeChallenge: pkce.challenge, state: state), state)
    }

    /// Mismas reglas que el flujo Gaia: `state` debe coincidir (CSRF) y `?error=` es cancelación.
    public func validate(callback: URL, expectedState: String) throws(AuthError) -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw .invalidResponse
        }
        let values = Dictionary(
            components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
        if values["error"] != nil || values["state"] != expectedState { throw .userCancelled }
        guard let code = values["code"], !code.isEmpty else { throw .invalidResponse }
        return code
    }
}

/// Sesión workforce recién iniciada. Redactada en cualquier texto.
public struct WorkforceSession: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let identity: WorkforceIdentity
    public let provider: WorkforcePoolProviderLocator
    public let tokens: TokenResponse
    public let issuedAt: Date

    public var sessionIdentity: SessionIdentity { .workforce(identity) }

    /// Credencial para Keychain (issuer STS; `email` = principal, no hay email).
    public func offlineCredential() throws(AuthError) -> OfflineCredential {
        guard let refresh = tokens.refreshToken, !refresh.isEmpty else { throw .missingRefreshToken }
        return OfflineCredential(
            issuer: .sts, email: identity.principal, refreshToken: refresh, idToken: "",
            scopes: tokens.scope?.split(separator: " ").map(String.init) ?? AuthPortalCodeFlow.defaultScopes,
            issuedAt: issuedAt)
    }

    public var description: String { "WorkforceSession(\(identity), provider: \(provider), tokens: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["identity": identity, "provider": provider.resourceName, "tokens": "<redacted>"])
    }
}

/// Orquesta el login workforce: portal → callback → STS → IntrospectToken.
public struct WorkforcePoolClient: Sendable {
    /// Abre `url` en el navegador y devuelve el callback del loopback.
    public typealias Authenticate = @Sendable (_ url: URL) async throws -> URL

    public let flow: AuthPortalCodeFlow
    public let sts: StsClient

    public init(provider: WorkforcePoolProviderLocator, sts: StsClient) {
        flow = AuthPortalCodeFlow(provider: provider, clientID: sts.clientID)
        self.sts = sts
    }

    public func signIn(redirectURI: URL, now: Date = Date(), authenticate: Authenticate) async throws -> WorkforceSession {
        let pkce = PKCE()
        let (url, state) = flow.build(redirectURI: redirectURI, pkce: pkce)
        let callback = try await authenticate(url)
        let code = try flow.validate(callback: callback, expectedState: state)
        let tokens = try await sts.exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI)
        if !AuthorizeURL.missingScopes(granted: tokens.scope).isEmpty { throw AuthError.consentRequired }
        return try await session(for: tokens, issuedAt: now)
    }

    /// Introspecciona `tokens.accessToken` y exige un `principal://` del pool configurado.
    public func session(for tokens: TokenResponse, issuedAt: Date = Date()) async throws -> WorkforceSession {
        let introspection = try await sts.introspect(token: tokens.accessToken)
        guard introspection.active else { throw AuthError.tokenExpired }
        // Un token de otro cliente o de otro pool no es una sesión de este login.
        if let client = introspection.clientID, client != sts.clientID { throw AuthError.invalidResponse }
        guard let identity = introspection.workforceIdentity,
              identity.pool == flow.provider.pool, identity.location == flow.provider.location
        else { throw AuthError.invalidResponse }
        return WorkforceSession(identity: identity, provider: flow.provider, tokens: tokens, issuedAt: issuedAt)
    }
}
