// AuthKit T-AUTH-3 tests: PKCE (vector RFC 7636) + TokenClient con stub HTTP.
import Testing
import Foundation
@testable import AuthKit

/// Stub URLProtocol para `/token` (sin red).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler?(request) ?? (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func stubbedSession(
    handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    StubURLProtocol.handler = handler
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

/// URLSession entrega el body como stream ante un URLProtocol custom.
func bodyString(of request: URLRequest) -> String? {
    if let body = request.httpBody { return String(data: body, encoding: .utf8) }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    return String(data: data, encoding: .utf8)
}

@Suite("PKCE")
struct PKCETests {
    @Test func rfc7636AppendixBVector() {
        // RFC 7636 §B (verificado contra rfc-editor.org): verifier fijo → challenge conocido.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedVerifierShape() {
        let pkce = PKCE()
        #expect(pkce.verifier.count == 43)
        #expect(pkce.challenge.count == 43)
        #expect(pkce.method == "S256")
        #expect(pkce.challenge == PKCE.challenge(for: pkce.verifier))
    }
}

@Suite("TokenClient", .serialized)  // handler stub global: sin paralelismo intra-suite
struct TokenClientTests {
    @Test func exchangePostsFormAndDecodes() async throws {
        var capturedBody: String?
        let session = stubbedSession { request in
            capturedBody = bodyString(of: request)
            let json = """
                {"access_token":"at-1","expires_in":3600,"refresh_token":"rt-1","id_token":"id-1","scope":"cloud"}
                """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let client = TokenClient(clientID: "test-client", session: session)
        let response = try await client.exchange(
            code: "code-1", verifier: "verifier-1",
            redirectURI: URL(string: "http://127.0.0.1:51236/authorize/")!)
        #expect(response.accessToken == "at-1")
        #expect(response.expiresIn == 3600)
        #expect(response.refreshToken == "rt-1")
        #expect(capturedBody?.contains("grant_type=authorization_code") == true)
        #expect(capturedBody?.contains("code_verifier=verifier-1") == true)
        #expect(capturedBody?.contains("client_id=test-client") == true)
    }

    @Test func refreshGrant() async throws {
        let session = stubbedSession { request in
            let json = """
                {"access_token":"at-2","expires_in":3600}
                """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let client = TokenClient(clientID: "test-client", session: session)
        let response = try await client.refresh(refreshToken: "rt-1")
        #expect(response.accessToken == "at-2")
        #expect(response.refreshToken == nil)
    }

    @Test func refreshStoredInFacade() async throws {
        let store = KeychainStore(service: "com.iap-mac.auth.test")
        let facade = CredentialFacade(store: store)
        let credential = OfflineCredential(
            issuer: .gaia, email: "refresh-\(UUID().uuidString)@example.com",
            refreshToken: "rt", idToken: "id", scopes: [])
        try await facade.authorize(credential, accessToken: "old", expiresAt: Date())
        await #expect(throws: AuthError.tokenExpired) { try await facade.validAccessToken() }
        try await facade.storeRefreshed(
            accessToken: "new", expiresIn: 3600, refreshToken: "rt-rotated",
            expectedGeneration: await facade.sessionGeneration)
        #expect(try await facade.validAccessToken() == "new")
        #expect(try store.load(issuer: .gaia, email: credential.email)?.refreshToken == "rt-rotated")
        await facade.revoke()
    }

    @Test func refreshAfterRevokeThrows() async throws {
        let facade = CredentialFacade(store: KeychainStore(service: "com.iap-mac.auth.test"))
        await #expect(throws: AuthError.tokenExpired) {
            try await facade.storeRefreshed(
                accessToken: "new", expiresIn: 60, refreshToken: nil,
                expectedGeneration: await facade.sessionGeneration)
        }
    }

    @Test func formEscapesSpecialChars() async throws {
        // Review #3: `+ & = ?` y espacios deben ir escapados (un `+` no puede
        // llegar como espacio).
        var capturedBody: String?
        let session = stubbedSession { request in
            capturedBody = bodyString(of: request)
            let json = """
                {"access_token":"at","expires_in":3600}
                """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let client = TokenClient(clientID: "id", session: session)
        _ = try await client.refresh(refreshToken: "a+b&c=d?e f")
        #expect(capturedBody?.contains("refresh_token=a%2Bb%26c%3Dd%3Fe%20f") == true)
    }

    @Test func clientSecretIncludedWhenSet() async throws {
        var capturedBody: String?
        let session = stubbedSession { request in
            capturedBody = bodyString(of: request)
            let json = """
                {"access_token":"at","expires_in":3600}
                """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let withSecret = TokenClient(clientID: "id", clientSecret: "s3cret", session: session)
        _ = try await withSecret.refresh(refreshToken: "rt")
        #expect(capturedBody?.contains("client_secret=s3cret") == true)
        let withoutSecret = TokenClient(clientID: "id", session: session)
        _ = try await withoutSecret.refresh(refreshToken: "rt")
        #expect(capturedBody?.contains("client_secret") == false)
    }

    @Test func transportErrorWrapped() async throws {
        struct Boom: Error {}
        let session = stubbedSession { _ in throw Boom() }
        let client = TokenClient(clientID: "id", session: session)
        do {
            _ = try await client.refresh(refreshToken: "rt")
            Issue.record("se esperaba AuthError.network")
        } catch AuthError.network {
            // OK: el error de transporte va envuelto (URLSession lo decora).
        }
    }

    @Test func tokenResponseRedacted() {
        let response = TokenResponse(
            accessToken: "secret-at", expiresIn: 3600, refreshToken: "secret-rt",
            idToken: "secret-id", scope: "cloud")
        #expect(!response.description.contains("secret-at"))
        #expect(!response.description.contains("secret-rt"))
        #expect(!response.debugDescription.contains("secret-id"))
    }

    @Test func revokePostsToken() async throws {
        var capturedBody: String?
        let session = stubbedSession { request in
            capturedBody = bodyString(of: request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let revoker = RevokeClient(session: session)
        #expect(await revoker.revoke(token: "doomed") == true)
        #expect(capturedBody?.contains("token=doomed") == true)
    }

    @Test func non200Throws() async throws {
        let session = stubbedSession { request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = TokenClient(clientID: "test-client", session: session)
        await #expect(throws: AuthError.invalidResponse) {
            try await client.refresh(refreshToken: "bad")
        }
    }
}
