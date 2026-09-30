import Foundation
import Testing
@testable import AuthKit

private final class LoginURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler?(request) ?? (
                HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data())
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func loginSession(
    handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    LoginURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LoginURLProtocol.self]
    return URLSession(configuration: configuration)
}

@Suite("AuthorizeURL")
struct AuthorizeURLTests {
    @Test func authorizationURLContainsRequiredParameters() throws {
        let redirectURI = URL(string: "http://127.0.0.1:54321/authorize")!
        let scopes = [AuthorizeURL.cloudScope, AuthorizeURL.emailScope]
        let request = AuthorizeURL(clientID: "test-client", scopes: scopes).build(
            redirectURI: redirectURI,
            pkce: PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            loginHint: "person@example.com")
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: try #require(components.queryItems).compactMap { item in
                item.value.map { (item.name, $0) }
            })

        #expect(components.scheme == "https")
        #expect(components.host == "accounts.google.com")
        #expect(components.path == "/o/oauth2/v2/auth")
        #expect(query["client_id"] == "test-client")
        #expect(query["redirect_uri"] == redirectURI.absoluteString)
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == scopes.joined(separator: " "))
        #expect(query["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == request.state)
        #expect(request.state.count == 43)
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "consent")
        #expect(query["login_hint"] == "person@example.com")
        #expect(request.url.absoluteString.contains("scope=https://www.googleapis.com/auth/cloud-platform%20https://www.googleapis.com/auth/userinfo.email"))
    }

    @Test func validationRejectsStateMismatchAndOAuthError() {
        let authorize = AuthorizeURL(clientID: "test-client")
        #expect(throws: AuthError.userCancelled) {
            try authorize.validate(
                callback: URL(string: "http://127.0.0.1/authorize?code=ok&state=wrong")!,
                expectedState: "expected")
        }
        #expect(throws: AuthError.userCancelled) {
            try authorize.validate(
                callback: URL(string: "http://127.0.0.1/authorize?error=access_denied&state=expected")!,
                expectedState: "expected")
        }
    }
}

@Suite("Login token wiring", .serialized)
struct LoginTokenWiringTests {
    @Test func sessionCallbackExchangesAndAuthorizes() async throws {
        let store = KeychainStore(service: "com.iap-mac.auth.login-test.\(UUID().uuidString)")
        let facade = CredentialFacade(store: store)
        let redirectURI = URL(string: "http://127.0.0.1:54321/authorize")!
        let pkce = PKCE()
        let authorize = AuthorizeURL(clientID: "test-client")
        let request = authorize.build(redirectURI: redirectURI, pkce: pkce)
        var callback = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
        callback.queryItems = [
            URLQueryItem(name: "code", value: "code-from-google"),
            URLQueryItem(name: "state", value: request.state),
        ]
        let callbackURL = callback.url!
        let session = LoginSession { _, _ in callbackURL }
        let urlSession = loginSession { request in
            let json = Data(#"{"access_token":"new-access","expires_in":3600,"refresh_token":"new-refresh","id_token":"header.payload.signature","scope":"https://www.googleapis.com/auth/cloud-platform"}"#.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                json)
        }

        let returnedCallback = try await session.authenticate(
            url: request.url,
            callbackScheme: redirectURI.scheme)
        let code = try authorize.validate(callback: returnedCallback, expectedState: request.state)
        let response = try await TokenClient(
            clientID: "test-client",
            session: urlSession
        ).exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI)
        let credential = OfflineCredential(
            issuer: .gaia,
            email: "wired@example.com",
            refreshToken: try #require(response.refreshToken),
            idToken: try #require(response.idToken),
            scopes: [AuthorizeURL.cloudScope])
        try await facade.authorize(
            credential,
            accessToken: response.accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)))

        #expect(try await facade.validAccessToken() == "new-access")
        #expect(await facade.currentEmail == "wired@example.com")
        await facade.revoke()
    }

    @Test func refresherUsesRefreshGrantAndStoresRotation() async throws {
        let store = KeychainStore(service: "com.iap-mac.auth.refresh-test.\(UUID().uuidString)")
        let facade = CredentialFacade(store: store)
        let credential = OfflineCredential(
            issuer: .gaia,
            email: "rotate@example.com",
            refreshToken: "old-refresh",
            idToken: "id-token",
            scopes: [AuthorizeURL.cloudScope])
        try await facade.authorize(credential, accessToken: "expired", expiresAt: .distantPast)
        let urlSession = loginSession { request in
            let json = Data(#"{"access_token":"refreshed-access","expires_in":3600,"refresh_token":"rotated-refresh"}"#.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                json)
        }

        let token = try await TokenRefresher().refreshedAccessToken(
            facade: facade,
            client: TokenClient(clientID: "test-client", session: urlSession))

        #expect(token == "refreshed-access")
        #expect(try await facade.validAccessToken() == "refreshed-access")
        #expect(await facade.currentOffline?.refreshToken == "rotated-refresh")
        #expect(try store.load(issuer: .gaia, email: credential.email)?.refreshToken == "rotated-refresh")
        await facade.revoke()
    }
}

@Suite("Offline restore")
struct OfflineRestoreTests {
    @Test func saveListLoadAndRestoreForcesRefresh() async throws {
        let store = KeychainStore(service: "com.iap-mac.auth.restore-test.\(UUID().uuidString)")
        let credential = OfflineCredential(
            issuer: .gaia,
            email: "restore@example.com",
            refreshToken: "refresh-token",
            idToken: "id-token",
            scopes: [AuthorizeURL.cloudScope])
        try store.save(credential)

        let accounts = try store.accounts()
        #expect(accounts.contains { $0.issuer == .gaia && $0.email == credential.email })
        let loaded = try store.load(issuer: .gaia, email: credential.email)
        let restored = try #require(loaded)
        let facade = CredentialFacade(store: store)
        await facade.restoreOffline(restored)
        await #expect(throws: AuthError.tokenExpired) {
            try await facade.validAccessToken()
        }
        await facade.revoke()
    }
}
