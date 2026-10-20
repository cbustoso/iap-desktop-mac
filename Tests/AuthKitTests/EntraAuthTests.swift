// GH-89: EntraAuthorizer (PKCE con loopback, device code, refresh por tenant)
// y AzureCredentialFacade (caché por tenant, refresh sin estampidas, rotación,
// Keychain `.azure` aislado por perfil, purge). Todo `/token` y `/devicecode`
// va a un URLProtocol stub: ninguna llamada sale a la red real.
import Foundation
import Testing
@testable import AuthKit

/// Stub de login.microsoftonline.com con un handler por `URLSession`.
private final class EntraStub: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let path: String
        let form: [String: String]
    }

    typealias Handler = @Sendable (Seen) -> (Int, String)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func session(_ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EntraStub.self]
        configuration.httpAdditionalHeaders = ["X-Stub-ID": id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = request.value(forHTTPHeaderField: "X-Stub-ID").flatMap { id in Self.lock.withLock { Self.handlers[id] } }
        let seen = Seen(path: request.url!.path, form: Self.form(request))
        let (status, json) = handler?(seen) ?? (500, "{}")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func form(_ request: URLRequest) -> [String: String] {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
        }
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
}

/// Registro thread-safe de lo que vio el stub (y otros contadores).
private final class Log<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

private let clientID = "11111111-2222-3333-4444-555555555555"
private let homeTenant = "aaaaaaaa-0000-0000-0000-000000000001"
private let otherTenant = "bbbbbbbb-0000-0000-0000-000000000002"
private let objectID = "cccccccc-0000-0000-0000-000000000003"

private func base64URL(_ json: String) -> String {
    Data(json.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func idToken(tid: String = homeTenant, oid: String = objectID, upn: String = "ada.lovelace@contoso.com") -> String {
    "\(base64URL(#"{"alg":"none"}"#)).\(base64URL(#"{"tid":"\#(tid)","oid":"\#(oid)","preferred_username":"\#(upn)"}"#)).sig"
}

private func tokenJSON(access: String = "eyJ.ACCESS-SECRET", refresh: String? = "0.REFRESH-SECRET", id: String? = idToken(), expires: Int = 3599) -> String {
    var fields = [#""token_type":"Bearer""#, #""access_token":"\#(access)""#, #""expires_in":\#(expires)"#,
                  #""scope":"https://management.core.windows.net//user_impersonation""#]
    if let refresh { fields.append(#""refresh_token":"\#(refresh)""#) }
    if let id { fields.append(#""id_token":"\#(id)""#) }
    return "{\(fields.joined(separator: ","))}"
}

private func errorJSON(_ error: String, codes: [Int] = []) -> String {
    #"{"error":"\#(error)","error_description":"AADSTS\#(codes.first ?? 0): detail.\r\nTrace ID: t\r\nCorrelation ID: c","error_codes":[\#(codes.map(String.init).joined(separator: ","))]}"#
}

private func config(redirectHost: String = "127.0.0.1") throws -> EntraClientConfig {
    try EntraClientConfig(clientID: clientID, redirectHost: redirectHost)
}

private func authorizer(_ session: URLSession, sleeps: Log<Int>? = nil, browser: @escaping EntraAuthorizer.BrowserOpener = { _ in }) throws -> EntraAuthorizer {
    try EntraAuthorizer(config: config(), session: session, openBrowser: browser, sleep: { duration in
        sleeps?.add(Int(duration.components.seconds))
    })
}

private func query(_ url: URL) -> [String: String] {
    Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
               uniquingKeysWith: { a, _ in a })
}

/// "Navegador" de test: sigue la redirección al loopback con `code`/`state`.
private func browser(code: String = "auth-code-SECRET", state override: String? = nil, error: String? = nil, saw: Log<URL>? = nil) -> EntraAuthorizer.BrowserOpener {
    { url in
        saw?.add(url)
        let params = query(url)
        var callback = URLComponents(string: params["redirect_uri"]!)!
        callback.queryItems = error.map { [URLQueryItem(name: "error", value: $0)] }
            ?? [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: override ?? params["state"])]
        _ = try? await URLSession(configuration: .ephemeral).data(from: callback.url!)
    }
}

@Suite("Entra: configuración (GH-89)")
struct EntraConfigTests {
    @Test func clientIDComesFromUIOverrideThenEnvironmentAndNeverFromTheRepo() throws {
        #expect(throws: EntraAuthError.clientNotConfigured) { try EntraClientConfig.resolve(environment: [:]) }
        #expect(throws: EntraAuthError.clientNotConfigured) {
            try EntraClientConfig.resolve(environment: [EntraClientConfig.environmentKey: "not-a-guid"])
        }
        #expect(try EntraClientConfig.resolve(environment: [EntraClientConfig.environmentKey: " \(clientID.uppercased()) "]).clientID == clientID)
        let suite = "com.iapdesktop.mac.tests.entra.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let override = "99999999-2222-3333-4444-555555555555"
        defaults.set(override, forKey: EntraClientConfig.defaultsKey)
        #expect(try EntraClientConfig.resolve(defaults: defaults, environment: [EntraClientConfig.environmentKey: clientID]).clientID == override)
    }

    @Test func tenantsCannotEscapeThePath() {
        for ok in ["organizations", homeTenant, "contoso.onmicrosoft.com"] { #expect(EntraClientConfig.isValidTenant(ok), "\(ok)") }
        for bad in ["", "../common", "a/b", "a?x=1", "a b", "tenant%2F"] { #expect(!EntraClientConfig.isValidTenant(bad), "\(bad)") }
    }

    @Test func authorizeURLIsPKCEWithARMScopeAndNoSecret() throws {
        let auth = try EntraAuthorizer(config: config(redirectHost: "localhost"), openBrowser: { _ in })
        let redirect = EntraAuthorizer.redirect(URL(string: "http://127.0.0.1:53682/authorize")!, host: "localhost")
        #expect(redirect.absoluteString == "http://localhost:53682/authorize")
        let pkce = PKCE()
        let url = auth.authorizeURL(tenant: "organizations", redirectURI: redirect, pkce: pkce, state: "st", loginHint: "ada@contoso.com")
        #expect(url.host == "login.microsoftonline.com")
        #expect(url.path == "/organizations/oauth2/v2.0/authorize")
        let params = query(url)
        #expect(params["client_id"] == clientID)
        #expect(params["code_challenge"] == pkce.challenge)
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["scope"] == "openid profile offline_access https://management.core.windows.net//user_impersonation")
        #expect(params["redirect_uri"] == "http://localhost:53682/authorize")
        #expect(params["login_hint"] == "ada@contoso.com")
        #expect(params["client_secret"] == nil)
        #expect(try config().adminConsentURL(tenant: homeTenant).absoluteString
            == "https://login.microsoftonline.com/\(homeTenant)/adminconsent?client_id=\(clientID)")
    }
}

@Suite("Entra: login interactivo PKCE (GH-89)")
struct EntraInteractiveTests {
    @Test func codeIsExchangedWithTheVerifierOverTheSameRedirect() async throws {
        let seen = Log<EntraStub.Seen>()
        let opened = Log<URL>()
        let session = EntraStub.session { request in
            seen.add(request)
            return (200, tokenJSON())
        }
        let auth = try authorizer(session, browser: browser(saw: opened))
        let response = try await auth.signInInteractive()
        let identity = try response.identity()
        #expect(identity == EntraIdentity(homeTenantID: homeTenant, objectID: objectID, username: "ada.lovelace@contoso.com"))
        #expect(identity.keychainAccount == "\(homeTenant):\(objectID)")

        let exchange = try #require(seen.all.first)
        let authorize = query(try #require(opened.all.first))
        #expect(seen.all.count == 1)
        #expect(exchange.path == "/organizations/oauth2/v2.0/token")
        #expect(exchange.form["grant_type"] == "authorization_code")
        #expect(exchange.form["code"] == "auth-code-SECRET")
        #expect(exchange.form["client_id"] == clientID)
        #expect(exchange.form["redirect_uri"] == authorize["redirect_uri"])
        #expect(PKCE.challenge(for: try #require(exchange.form["code_verifier"])) == authorize["code_challenge"])
        #expect(exchange.form["client_secret"] == nil)  // public client
    }

    @Test func wrongStateIsRejectedBeforeAnyExchange() async throws {
        let seen = Log<EntraStub.Seen>()
        let auth = try authorizer(EntraStub.session { seen.add($0); return (200, tokenJSON()) }, browser: browser(state: "forged"))
        await #expect(throws: EntraAuthError.stateMismatch) { try await auth.signInInteractive() }
        #expect(seen.all.isEmpty)
    }

    @Test func errorCallbackIsACancellation() async throws {
        let auth = try authorizer(EntraStub.session { _ in (200, tokenJSON()) }, browser: browser(error: "access_denied"))
        await #expect(throws: EntraAuthError.userCancelled) { try await auth.signInInteractive() }
    }

    @Test func browserFailureDoesNotWaitForTheTimeout() async throws {
        struct NoBrowser: Error {}
        let auth = try authorizer(EntraStub.session { _ in (200, tokenJSON()) }, browser: { _ in throw NoBrowser() })
        let started = Date()
        await #expect(throws: NoBrowser.self) { try await auth.signInInteractive(timeoutSeconds: 30) }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func tokenResponsesWithoutIdentityAreRejected() {
        #expect(throws: EntraAuthError.missingIdentity) { try EntraTokenResponse(accessToken: "a", expiresIn: 1).identity() }
        #expect(throws: EntraAuthError.missingIdentity) {
            try EntraTokenResponse(accessToken: "a", expiresIn: 1, idToken: idToken(tid: "../evil")).identity()
        }
    }
}

@Suite("Entra: device code (GH-89)")
struct EntraDeviceCodeTests {
    private static let deviceJSON = #"""
    {"device_code":"DEVICE-SECRET","user_code":"ABCD-EFGH","verification_uri":"https://microsoft.com/devicelogin","expires_in":900,"interval":5,"message":"To sign in, use a web browser…"}
    """#

    @Test func pollsThroughPendingAndSlowDownUntilSuccess() async throws {
        let seen = Log<EntraStub.Seen>()
        let sleeps = Log<Int>()
        let prompts = Log<DeviceCodePrompt>()
        let session = EntraStub.session { request in
            seen.add(request)
            if request.path.hasSuffix("/devicecode") { return (200, Self.deviceJSON) }
            switch seen.all.count {
            case 2: return (400, errorJSON("authorization_pending", codes: [70016]))
            case 3: return (400, errorJSON("slow_down"))
            default: return (200, tokenJSON())
            }
        }
        let response = try await authorizer(session, sleeps: sleeps).signInWithDeviceCode { prompts.add($0) }
        #expect(try response.identity().homeTenantID == homeTenant)
        #expect(prompts.all == [DeviceCodePrompt(
            userCode: "ABCD-EFGH", verificationURI: URL(string: "https://microsoft.com/devicelogin")!, expiresIn: 900,
            message: "To sign in, use a web browser…")])
        #expect(sleeps.all == [5, 5, 10])  // slow_down suma 5 s
        let polls = seen.all.dropFirst()
        #expect(seen.all.first?.path == "/organizations/oauth2/v2.0/devicecode")
        #expect(seen.all.first?.form["scope"] == EntraClientConfig.signInScopes.joined(separator: " "))
        #expect(polls.allSatisfy {
            $0.path == "/organizations/oauth2/v2.0/token"
                && $0.form["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code"
                && $0.form["device_code"] == "DEVICE-SECRET" && $0.form["client_id"] == clientID
        })
    }

    @Test func expiresWhenTheUserNeverFinishes() async throws {
        let short = #"{"device_code":"d","user_code":"u","verification_uri":"https://microsoft.com/devicelogin","expires_in":10,"interval":5}"#
        let sleeps = Log<Int>()
        let session = EntraStub.session { request in
            request.path.hasSuffix("/devicecode") ? (200, short) : (400, errorJSON("authorization_pending"))
        }
        await #expect(throws: EntraAuthError.deviceCodeExpired) {
            try await authorizer(session, sleeps: sleeps).signInWithDeviceCode { _ in }
        }
        #expect(sleeps.all == [5, 5])
    }

    @Test(arguments: [
        ("authorization_declined", [Int](), EntraAuthError.deviceCodeDeclined),
        ("expired_token", [], .deviceCodeExpired),
        ("invalid_grant", [53003], .blockedByConditionalAccess),
    ])
    func terminalPollingErrors(error: String, codes: [Int], expected: EntraAuthError) async throws {
        let session = EntraStub.session { request in
            request.path.hasSuffix("/devicecode") ? (200, Self.deviceJSON) : (400, errorJSON(error, codes: codes))
        }
        await #expect(throws: expected) { try await authorizer(session).signInWithDeviceCode { _ in } }
    }

    @Test func blockedOrDisabledBeforeShowingAnyCode() async throws {
        let prompts = Log<DeviceCodePrompt>()
        for (codes, expected) in [([53003], EntraAuthError.blockedByConditionalAccess), ([7_000_218], .publicClientFlowsDisabled)] {
            let session = EntraStub.session { _ in (400, errorJSON("invalid_request", codes: codes)) }
            await #expect(throws: expected) { try await authorizer(session).signInWithDeviceCode { prompts.add($0) } }
        }
        #expect(prompts.all.isEmpty)
    }
}

@Suite("Entra: refresh por tenant (GH-89)")
struct EntraRefreshTests {
    @Test func refreshTargetsTheTenantWithTheARMScope() async throws {
        let seen = Log<EntraStub.Seen>()
        let session = EntraStub.session { seen.add($0); return (200, tokenJSON(refresh: "0.ROTATED", id: nil)) }
        let response = try await authorizer(session).refresh("0.REFRESH-SECRET", tenantID: otherTenant)
        #expect(response.refreshToken == "0.ROTATED")
        let request = try #require(seen.all.first)
        #expect(request.path == "/\(otherTenant)/oauth2/v2.0/token")
        #expect(request.form == [
            "grant_type": "refresh_token", "client_id": clientID, "refresh_token": "0.REFRESH-SECRET",
            "scope": "https://management.core.windows.net//user_impersonation offline_access",
        ])
    }

    @Test func invalidTenantNeverReachesTheNetwork() async throws {
        let seen = Log<EntraStub.Seen>()
        let auth = try authorizer(EntraStub.session { seen.add($0); return (200, tokenJSON()) })
        await #expect(throws: EntraAuthError.invalidTenant) { try await auth.refresh("r", tenantID: "../common") }
        #expect(seen.all.isEmpty)
    }

    @Test func errorsAreClassified() async throws {
        let consent = try config().adminConsentURL(tenant: otherTenant)
        let cases: [(Int, String, EntraAuthError)] = [
            (400, errorJSON("invalid_grant", codes: [70008]), .requiresSignIn),
            (400, errorJSON("interaction_required", codes: [50076]), .interactionRequired(tenantID: otherTenant)),
            (400, errorJSON("invalid_grant", codes: [50079]), .interactionRequired(tenantID: otherTenant)),
            (400, errorJSON("invalid_grant", codes: [65001]), .consentRequired(adminConsentURL: consent)),
            (400, errorJSON("invalid_grant", codes: [53003]), .blockedByConditionalAccess),
            (401, errorJSON("invalid_client", codes: [7_000_215]), .tokenEndpoint(status: 401, error: "invalid_client", codes: [7_000_215])),
            (503, "<html>", .tokenEndpoint(status: 503, error: nil, codes: [])),
            (200, "{}", .malformedResponse),
        ]
        for (status, body, expected) in cases {
            let auth = try authorizer(EntraStub.session { _ in (status, body) })
            await #expect(throws: expected) { try await auth.refresh("r", tenantID: otherTenant) }
        }
    }

    @Test func secretsNeverAppearInDescriptions() throws {
        let response = EntraTokenResponse(accessToken: "eyJ.ACCESS-SECRET", expiresIn: 1, refreshToken: "0.REFRESH-SECRET", idToken: idToken())
        let identity = try response.identity()
        let offline = AzureOfflineCredential(identity: identity, refreshToken: "0.REFRESH-SECRET")
        for text in [String(describing: response), String(reflecting: response), String(describing: offline), String(reflecting: offline), "\(identity)"] {
            for secret in ["ACCESS-SECRET", "REFRESH-SECRET", "ada.lovelace", objectID] {
                #expect(!text.contains(secret), "\(text)")
            }
        }
        #expect("\(identity)".contains("a…@contoso.com"))
    }
}

/// Reloj controlable para la caducidad de los access tokens.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 2_000_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Perfil Azure de test con Keychain real namespaced; `purge` al terminar.
private struct TestProfile {
    let env = ProfileEnvironment(id: .generate(), migrationCompleted: true)
    var store: AzureKeychainStore { AzureKeychainStore(environment: env) }
    func tearDown() { try? env.purge() }
}

@Suite("Azure: AzureCredentialFacade (GH-89)", .serialized)
struct AzureCredentialFacadeTests {
    @Test func homeTenantTokenIsCachedAndOtherTenantsRefreshOnce() async throws {
        let profile = TestProfile()
        defer { profile.tearDown() }
        let seen = Log<EntraStub.Seen>()
        let session = EntraStub.session { request in
            seen.add(request)
            Thread.sleep(forTimeInterval: 0.1)  // refresh lento: los demás llegan con él en vuelo
            return (200, tokenJSON(access: "eyJ.OTHER-TENANT", refresh: "0.ROTATED", id: nil))
        }
        let facade = AzureCredentialFacade(store: profile.store, authorizer: try authorizer(session))
        let identity = try await facade.authorize(EntraTokenResponse(
            accessToken: "eyJ.HOME", expiresIn: 3599, refreshToken: "0.REFRESH-SECRET", idToken: idToken()))
        #expect(identity.homeTenantID == homeTenant)
        #expect(try await facade.accessToken(tenantID: homeTenant) == "eyJ.HOME")
        #expect(seen.all.isEmpty)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await facade.accessToken(tenantID: otherTenant) } }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(tokens == Array(repeating: "eyJ.OTHER-TENANT", count: 8))
        #expect(seen.all.count == 1)  // sin estampida
        #expect(seen.all.first?.form["refresh_token"] == "0.REFRESH-SECRET")

        // Rotación persistida: un facade nuevo (reinicio de la app) la restaura.
        let restarted = AzureCredentialFacade(store: profile.store, authorizer: try authorizer(session))
        #expect(try await restarted.restore())
        #expect(await restarted.identity == identity)
        _ = try await restarted.accessToken(tenantID: otherTenant)
        #expect(seen.all.last?.form["refresh_token"] == "0.ROTATED")
    }

    @Test func expiredTokensAreRefreshedWithSkew() async throws {
        let profile = TestProfile()
        defer { profile.tearDown() }
        let clock = Clock()
        let seen = Log<EntraStub.Seen>()
        let session = EntraStub.session { seen.add($0); return (200, tokenJSON(access: "eyJ.NEW", refresh: nil, id: nil)) }
        let facade = AzureCredentialFacade(store: profile.store, authorizer: try authorizer(session), skew: 60, now: { clock.now })
        try await facade.authorize(EntraTokenResponse(accessToken: "eyJ.OLD", expiresIn: 3600, refreshToken: "0.R", idToken: idToken()))
        clock.advance(3600 - 61)
        #expect(try await facade.accessToken(tenantID: homeTenant) == "eyJ.OLD")
        clock.advance(2)
        #expect(try await facade.accessToken(tenantID: homeTenant) == "eyJ.NEW")
        #expect(seen.all.map(\.path) == ["/\(homeTenant)/oauth2/v2.0/token"])
        // Sin refresh token rotado se conserva el anterior.
        let restored = AzureCredentialFacade(store: profile.store, authorizer: try authorizer(session))
        try await restored.restore()
        _ = try await restored.accessToken(tenantID: otherTenant)
        #expect(seen.all.last?.form["refresh_token"] == "0.R")
    }

    @Test func noSessionMeansSignInAndRefreshErrorsPropagate() async throws {
        let profile = TestProfile()
        defer { profile.tearDown() }
        let session = EntraStub.session { _ in (400, errorJSON("invalid_grant", codes: [700_082])) }
        let facade = AzureCredentialFacade(store: profile.store, authorizer: try authorizer(session))
        #expect(try await facade.restore() == false)
        await #expect(throws: EntraAuthError.requiresSignIn) { try await facade.accessToken(tenantID: homeTenant) }
        try await facade.authorize(EntraTokenResponse(accessToken: "a", expiresIn: 3599, refreshToken: "0.R", idToken: idToken()))
        await #expect(throws: EntraAuthError.requiresSignIn) { try await facade.accessToken(tenantID: otherTenant) }
        // Un fallo de un tenant no tira la sesión ni la caché del resto.
        #expect(try await facade.accessToken(tenantID: homeTenant) == "a")
        await #expect(throws: EntraAuthError.missingRefreshToken) {
            try await facade.authorize(EntraTokenResponse(accessToken: "a", expiresIn: 1, idToken: idToken()))
        }
    }

    @Test func signOutDuringARefreshDiscardsItsResult() async throws {
        let profile = TestProfile()
        defer { profile.tearDown() }
        let session = EntraStub.session { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return (200, tokenJSON(access: "eyJ.LATE", refresh: "0.LATE", id: nil))
        }
        let facade = AzureCredentialFacade(store: profile.store, authorizer: try authorizer(session))
        try await facade.authorize(EntraTokenResponse(accessToken: "a", expiresIn: 3599, refreshToken: "0.R", idToken: idToken()))
        let pending = Task { try await facade.accessToken(tenantID: otherTenant) }
        try await Task.sleep(for: .milliseconds(100))
        try await facade.signOut()
        await #expect(throws: EntraAuthError.sessionChanged) { try await pending.value }
        #expect(try profile.store.accounts().isEmpty)  // el refresh tardío no resucita nada
        #expect(await facade.isSignedIn == false)
    }

    @Test func twoProfilesNeverShareTokensAndPurgeOnlyTouchesItsOwn() async throws {
        let a = TestProfile()
        let b = TestProfile()
        defer { a.tearDown(); b.tearDown() }
        let session = EntraStub.session { _ in (500, "{}") }
        let facadeA = AzureCredentialFacade(store: a.store, authorizer: try authorizer(session))
        let facadeB = AzureCredentialFacade(store: b.store, authorizer: try authorizer(session))
        // Misma cuenta en dos perfiles (p. ej. dos app registrations): no colisionan.
        try await facadeA.authorize(EntraTokenResponse(accessToken: "eyJ.A", expiresIn: 3599, refreshToken: "0.A", idToken: idToken()))
        try await facadeB.authorize(EntraTokenResponse(accessToken: "eyJ.B", expiresIn: 3599, refreshToken: "0.B", idToken: idToken()))
        #expect(a.store.service != b.store.service)
        let account = "\(homeTenant):\(objectID)"
        #expect(try a.store.load(account: account)?.refreshToken == "0.A")
        #expect(try b.store.load(account: account)?.refreshToken == "0.B")

        try a.env.purge()  // eliminar el perfil A (A1.4)
        #expect(try a.store.accounts().isEmpty)
        #expect(try b.store.load(account: account)?.refreshToken == "0.B")
        let restoredB = AzureCredentialFacade(store: b.store, authorizer: try authorizer(session))
        #expect(try await restoredB.restore())
        #expect(try await facadeB.accessToken(tenantID: homeTenant) == "eyJ.B")
    }

    @Test func anotherAccountReplacesThePreviousOneInTheSameProfile() async throws {
        let profile = TestProfile()
        defer { profile.tearDown() }
        let facade = AzureCredentialFacade(store: profile.store, authorizer: try authorizer(EntraStub.session { _ in (500, "{}") }))
        try await facade.authorize(EntraTokenResponse(accessToken: "a", expiresIn: 3599, refreshToken: "0.1", idToken: idToken()))
        let other = "dddddddd-0000-0000-0000-000000000004"
        try await facade.authorize(EntraTokenResponse(accessToken: "b", expiresIn: 3599, refreshToken: "0.2", idToken: idToken(oid: other)))
        #expect(try profile.store.accounts() == ["\(homeTenant):\(other)"])
        try await facade.purge()
        #expect(try profile.store.accounts().isEmpty)
    }
}
