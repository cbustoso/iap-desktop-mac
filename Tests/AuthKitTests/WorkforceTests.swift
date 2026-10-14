// GH-67 (T-AUTH-7): WIF — locator, parser principal://, auth portal, STS
// (oauthtoken/introspect/revoke) con stubs, flujo completo, OS Login tipado y
// redacción de secretos.
import Foundation
import Testing
@testable import AuthKit

/// Stub STS con un handler por `URLSession` (cabecera `X-Stub-ID`).
private final class StsStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, [String: String]) -> (Int, String)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func session(_ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StsStub.self]
        configuration.httpAdditionalHeaders = ["X-Stub-ID": id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = request.value(forHTTPHeaderField: "X-Stub-ID").flatMap { id in Self.lock.withLock { Self.handlers[id] } }
        let (status, json) = handler?(request, Self.form(request)) ?? (500, "{}")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func form(_ request: URLRequest) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: body(request), as: UTF8.self)
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
}

/// Peticiones recibidas por el stub. `@unchecked`: bajo `lock`.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(path: String, form: [String: String], auth: String?)] = []
    func add(_ request: URLRequest, _ form: [String: String]) {
        lock.withLock { items.append((request.url!.path, form, request.value(forHTTPHeaderField: "Authorization"))) }
    }
    var all: [(path: String, form: [String: String], auth: String?)] { lock.withLock { items } }
}

private let provider = WorkforcePoolProviderLocator(pool: "corp-pool", provider: "okta-oidc")!
private let principal = "principal://iam.googleapis.com/locations/global/workforcePools/corp-pool/subject/ada%40corp.example"
private let accessToken = "ya29.workforce-access-token-SECRET"
private let refreshToken = "1//workforce-refresh-SECRET"
private let clientSecret = "GOCSPX-super-secret"
private let redirect = URL(string: "http://127.0.0.1:53682/")!

private func tokenJSON(scope: String = "https://www.googleapis.com/auth/cloud-platform") -> String {
    #"{"access_token":"\#(accessToken)","expires_in":3599,"refresh_token":"\#(refreshToken)","scope":"\#(scope)","token_type":"Bearer"}"#
}

private func introspectJSON(active: Bool = true, client: String = "wf-client", username: String = principal) -> String {
    #"{"active":\#(active),"client_id":"\#(client)","username":"\#(username)","scope":"https://www.googleapis.com/auth/cloud-platform","exp":1800000000}"#
}

private func sts(secret: String? = clientSecret, _ handler: @escaping StsStub.Handler) -> StsClient {
    StsClient(clientID: "wf-client", clientSecret: secret, session: StsStub.session(handler))
}

@Suite("Workforce: identidades (GH-67)")
struct WorkforceIdentityTests {
    @Test func providerLocatorRoundTrip() throws {
        #expect(provider.resourceName == "locations/global/workforcePools/corp-pool/providers/okta-oidc")
        #expect(WorkforcePoolProviderLocator(provider.resourceName) == provider)
        #expect(WorkforcePoolProviderLocator("locations/global/workforcePools/p/providers") == nil)
        #expect(WorkforcePoolProviderLocator("locations/global/workloadIdentityPools/p/providers/x") == nil)
        // IDs que permitirían inyectar parámetros en la URL del portal.
        #expect(WorkforcePoolProviderLocator(pool: "a&scope=evil", provider: "x") == nil)
        #expect(WorkforcePoolProviderLocator(pool: "Corp", provider: "x") == nil)
        #expect(WorkforcePoolProviderLocator(pool: "", provider: "x") == nil)
    }

    @Test func parsesWorkforcePrincipal() throws {
        let identity = try #require(WorkforceIdentity(principal: principal))
        #expect(identity.location == "global")
        #expect(identity.pool == "corp-pool")
        #expect(identity.subject == "ada@corp.example")  // percent-decoded
        #expect(identity.principal == "principal://iam.googleapis.com/locations/global/workforcePools/corp-pool/subject/ada@corp.example")
        #expect(WorkforceIdentity(principal: identity.principal) == identity)
        #expect(WorkforceIdentity(principal: "principal://iam.googleapis.com/locations/global/workforcePools/p00l/subject/00u1abcd")?.subject == "00u1abcd")
    }

    @Test func rejectsNonWorkforcePrincipals() {
        for bad in [
            "principalSet://iam.googleapis.com/locations/global/workforcePools/corp-pool/group/admins",
            "principal://iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/p/subject/s",
            "principal://evil.example.com/locations/global/workforcePools/corp-pool/subject/s",
            "principal://iam.googleapis.com/locations/global/workforcePools/corp-pool/subject/",
            "principal://iam.googleapis.com/locations/global/workforcePools/corp-pool/subject/a/b",
            "principal://iam.googleapis.com/locations/global/workforcePools/Bad_Pool/subject/s",
            "principal://iam.googleapis.com/locations/global/workforcePools/corp-pool/subject/a%0Ab",
            "ada@corp.example",
            "",
        ] {
            #expect(WorkforceIdentity(principal: bad) == nil, "\(bad)")
        }
    }

    @Test func osLoginRejectsWorkforceWithTypedError() throws {
        let workforce = SessionIdentity.workforce(try #require(WorkforceIdentity(principal: principal)))
        #expect(throws: AuthError.workforceNotSupported) { try OsLoginEligibility.requireSupported(workforce) }
        #expect(!OsLoginEligibility.isSupported(workforce))
        #expect(workforce.isWorkforce)
        #expect(workforce.issuer == .sts)
        let gaia = SessionIdentity.gaia(email: "ada@example.com")
        try OsLoginEligibility.requireSupported(gaia)
        #expect(OsLoginEligibility.isSupported(gaia))
        #expect(gaia.issuer == .gaia)
        #expect(LoginFailure.message(for: AuthError.workforceNotSupported, at: .verifyingIdentity)
            .contains("OS Login does not support workforce identities"))
    }

    @Test func identityNeverPrintsFullSubject() throws {
        let identity = try #require(WorkforceIdentity(principal: principal))
        var dumped = ""
        dump(identity, to: &dumped)
        for text in [String(describing: identity), String(reflecting: identity), dumped,
                     String(describing: SessionIdentity.workforce(identity)), String(describing: SessionIdentity.gaia(email: "ada@example.com"))] {
            #expect(!text.contains("ada@"), "\(text)")
        }
        #expect(identity.redactedSubject == "@corp.example")
        #expect(WorkforceIdentity(principal: "principal://iam.googleapis.com/locations/global/workforcePools/p00l/subject/00u1")?.redactedSubject == "<redacted>")
    }
}

@Suite("Workforce: auth portal (GH-67)")
struct AuthPortalCodeFlowTests {
    @Test func authorizeURLCarriesProviderPkceAndState() throws {
        let flow = AuthPortalCodeFlow(provider: provider, clientID: "wf-client")
        let pkce = PKCE()
        let (url, state) = flow.build(redirectURI: redirect, pkce: pkce)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "auth.cloud.google")
        #expect(components.path == "/authorize")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["provider_name"] == "locations/global/workforcePools/corp-pool/providers/okta-oidc")
        #expect(items["client_id"] == "wf-client")
        #expect(items["redirect_uri"] == redirect.absoluteString)
        #expect(items["response_type"] == "code")
        #expect(items["scope"] == "https://www.googleapis.com/auth/cloud-platform")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == state)
        #expect(items["code_verifier"] == nil)  // el verificador nunca sale en la URL
        #expect(state.count >= 43)
    }

    @Test func callbackValidation() throws {
        let flow = AuthPortalCodeFlow(provider: provider, clientID: "wf-client")
        #expect(try flow.validate(callback: URL(string: "http://127.0.0.1/?code=abc&state=s1")!, expectedState: "s1") == "abc")
        #expect(throws: AuthError.userCancelled) { try flow.validate(callback: URL(string: "http://127.0.0.1/?code=abc&state=forged")!, expectedState: "s1") }
        #expect(throws: AuthError.userCancelled) { try flow.validate(callback: URL(string: "http://127.0.0.1/?error=access_denied&state=s1")!, expectedState: "s1") }
        #expect(throws: AuthError.invalidResponse) { try flow.validate(callback: URL(string: "http://127.0.0.1/?state=s1")!, expectedState: "s1") }
    }
}

@Suite("Workforce: STS (GH-67)")
struct StsClientTests {
    @Test func exchangeUsesBasicAuthAndNeverPutsSecretInBody() async throws {
        let seen = Seen()
        let client = sts { request, form in
            seen.add(request, form)
            return (200, tokenJSON())
        }
        let tokens = try await client.exchange(code: "auth-code-SECRET", verifier: "verifier-SECRET", redirectURI: redirect)
        #expect(tokens.accessToken == accessToken)
        #expect(tokens.refreshToken == refreshToken)
        let request = try #require(seen.all.first)
        #expect(request.path == "/v1/oauthtoken")
        #expect(request.form == [
            "grant_type": "authorization_code", "code": "auth-code-SECRET",
            "redirect_uri": redirect.absoluteString, "code_verifier": "verifier-SECRET",
        ])
        let basic = try #require(request.auth)
        #expect(basic.hasPrefix("Basic "))
        #expect(String(decoding: Data(base64Encoded: String(basic.dropFirst(6)))!, as: UTF8.self) == "wf-client:GOCSPX-super-secret")
    }

    @Test func withoutSecretClientIDGoesInBody() async throws {
        let seen = Seen()
        let client = sts(secret: nil) { request, form in
            seen.add(request, form)
            return (200, tokenJSON())
        }
        _ = try await client.refresh(refreshToken: refreshToken)
        let request = try #require(seen.all.first)
        #expect(request.auth == nil)
        #expect(request.form == ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": "wf-client"])
    }

    @Test func errorsAreTyped() async {
        let rejected = sts { _, _ in (400, #"{"error":"invalid_grant","error_description":"Code expired"}"#) }
        await #expect(throws: AuthError.tokenEndpoint(status: 400, error: "invalid_grant", description: "Code expired")) {
            try await rejected.exchange(code: "c", verifier: "v", redirectURI: redirect)
        }
        let garbage = sts { _, _ in (200, "<html>") }
        await #expect(throws: AuthError.malformedTokenResponse) { try await garbage.refresh(refreshToken: "r") }
        let unconfigured = StsClient(clientID: " ", session: StsStub.session { _, _ in Issue.record("no debía llamar"); return (500, "") })
        await #expect(throws: AuthError.clientNotConfigured) { try await unconfigured.refresh(refreshToken: "r") }
    }

    @Test func introspectReturnsWorkforceIdentity() async throws {
        let seen = Seen()
        let client = sts { request, form in
            seen.add(request, form)
            return (200, introspectJSON())
        }
        let result = try await client.introspect(token: accessToken)
        #expect(result.active)
        #expect(result.clientID == "wf-client")
        #expect(result.workforceIdentity?.pool == "corp-pool")
        #expect(result.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(seen.all.first?.path == "/v1/introspect")
        #expect(seen.all.first?.form == ["token": accessToken])
        #expect(!String(describing: result).contains("ada@"))
        // `exp` como string y `active` ausente.
        let alt = try JSONDecoder().decode(StsIntrospection.self, from: Data(#"{"exp":"42","username":"x"}"#.utf8))
        #expect(!alt.active)
        #expect(alt.expiresAt == Date(timeIntervalSince1970: 42))
        #expect(alt.workforceIdentity == nil)
    }

    @Test func revokeIsBestEffort() async {
        let seen = Seen()
        #expect(await sts { request, form in seen.add(request, form); return (200, "{}") }.revoke(token: refreshToken))
        #expect(seen.all.first?.path == "/v1/revoke")
        #expect(!(await sts { _, _ in (503, "{}") }.revoke(token: refreshToken)))
    }

    @Test func clientDescriptionHidesSecret() {
        let text = String(describing: sts { _, _ in (200, "{}") })
        #expect(!text.contains("GOCSPX"))
        #expect(text.contains("<redacted>"))
    }
}

@Suite("Workforce: flujo completo (GH-67)")
struct WorkforcePoolClientTests {
    private func stubbedClient(introspect: String = introspectJSON(), token: String = tokenJSON(), seen: Seen = Seen()) -> WorkforcePoolClient {
        WorkforcePoolClient(provider: provider, sts: sts { request, form in
            seen.add(request, form)
            return request.url!.path == "/v1/introspect" ? (200, introspect) : (200, token)
        })
    }

    /// Simula el navegador: devuelve el callback con el `state` de la URL.
    private func browser(code: String = "auth-code-SECRET") -> WorkforcePoolClient.Authenticate {
        { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "http://127.0.0.1:53682/?code=\(code)&state=\(state)")!
        }
    }

    @Test func signInExchangesThenIntrospects() async throws {
        let seen = Seen()
        let session = try await stubbedClient(seen: seen).signIn(
            redirectURI: redirect, now: Date(timeIntervalSince1970: 100), authenticate: browser())
        #expect(seen.all.map(\.path) == ["/v1/oauthtoken", "/v1/introspect"])
        #expect(seen.all[1].form == ["token": accessToken])  // se introspecciona el access token canjeado
        #expect(session.identity.subject == "ada@corp.example")
        #expect(session.sessionIdentity.isWorkforce)
        #expect(throws: AuthError.workforceNotSupported) { try OsLoginEligibility.requireSupported(session.sessionIdentity) }

        let credential = try session.offlineCredential()
        #expect(credential.issuer == .sts)
        #expect(credential.email == session.identity.principal)
        #expect(credential.refreshToken == refreshToken)
        #expect(credential.scopes == ["https://www.googleapis.com/auth/cloud-platform"])
        #expect(credential.issuedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func inactiveOrForeignTokensAreRejected() async {
        await #expect(throws: AuthError.tokenExpired) {
            try await stubbedClient(introspect: introspectJSON(active: false)).signIn(redirectURI: redirect, authenticate: browser())
        }
        await #expect(throws: AuthError.invalidResponse) {  // otro cliente OAuth
            try await stubbedClient(introspect: introspectJSON(client: "someone-else")).signIn(redirectURI: redirect, authenticate: browser())
        }
        await #expect(throws: AuthError.invalidResponse) {  // otro pool
            try await stubbedClient(introspect: introspectJSON(
                username: "principal://iam.googleapis.com/locations/global/workforcePools/other-pool/subject/x"))
                .signIn(redirectURI: redirect, authenticate: browser())
        }
        await #expect(throws: AuthError.invalidResponse) {  // no es un principal workforce
            try await stubbedClient(introspect: introspectJSON(username: "ada@corp.example")).signIn(redirectURI: redirect, authenticate: browser())
        }
    }

    @Test func forgedStateNeverReachesSts() async {
        let seen = Seen()
        await #expect(throws: AuthError.userCancelled) {
            try await stubbedClient(seen: seen).signIn(redirectURI: redirect) { _ in
                URL(string: "http://127.0.0.1:53682/?code=c&state=forged")!
            }
        }
        #expect(seen.all.isEmpty)
    }

    @Test func cloudScopeDeclinedIsConsentRequired() async {
        await #expect(throws: AuthError.consentRequired) {
            try await stubbedClient(token: tokenJSON(scope: "openid")).signIn(redirectURI: redirect, authenticate: browser())
        }
    }

    @Test func missingRefreshTokenCannotBePersisted() async throws {
        let token = #"{"access_token":"\#(accessToken)","expires_in":3599}"#
        let session = try await stubbedClient(token: token).signIn(redirectURI: redirect, authenticate: browser())
        #expect(throws: AuthError.missingRefreshToken) { try session.offlineCredential() }
    }

    @Test func sessionAndCredentialNeverPrintSecrets() async throws {
        let session = try await stubbedClient().signIn(redirectURI: redirect, authenticate: browser())
        var dumped = ""
        dump(session, to: &dumped)
        let credential = try session.offlineCredential()
        for text in [String(describing: session), String(reflecting: session), dumped, String(reflecting: credential)] {
            for secret in [accessToken, refreshToken, clientSecret, "auth-code-SECRET", "ada@corp"] {
                #expect(!text.contains(secret), "\(text)")
            }
        }
    }
}
