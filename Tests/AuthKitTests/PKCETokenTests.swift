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
private func bodyString(of request: URLRequest) -> String? {
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
        let facade = CredentialFacade(store: KeychainStore(service: "com.iap-mac.auth.test"))
        let credential = OfflineCredential(
            issuer: .gaia, email: "refresh-\(UUID().uuidString)@example.com",
            refreshToken: "rt", idToken: "id", scopes: [])
        try await facade.authorize(credential, accessToken: "old", expiresAt: Date())
        await #expect(throws: AuthError.tokenExpired) { try await facade.validAccessToken() }
        await facade.storeRefreshed(accessToken: "new", expiresIn: 3600)
        #expect(try await facade.validAccessToken() == "new")
        try await facade.revoke()
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
