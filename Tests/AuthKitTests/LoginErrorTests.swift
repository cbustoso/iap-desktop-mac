// CBU-28b: errores de login específicos (cada rama) y sin secretos.
import Foundation
import Testing
@testable import AuthKit

/// Stub HTTP con handler `@Sendable` (CFNetwork lo invoca en su propio hilo).
private final class TokenStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case http(status: Int, body: String)
        case transport(URLError.Code)
    }

    nonisolated(unsafe) static var reply: Reply = .http(status: 500, body: "")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.reply {
        case .http(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .transport(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

private let secretCode = "4/0AQSecretAuthorizationCode"
private let secretVerifier = "verifier-should-never-appear"

private func exchange(replying reply: TokenStubProtocol.Reply) async throws -> TokenResponse {
    TokenStubProtocol.reply = reply
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TokenStubProtocol.self]
    let client = TokenClient(clientID: "123-abc.apps.googleusercontent.com", session: URLSession(configuration: configuration))
    return try await client.exchange(
        code: secretCode, verifier: secretVerifier,
        redirectURI: URL(string: "http://127.0.0.1:50123/authorize")!)
}

private func jwt(payload: String) -> String {
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJSUzI1NiJ9.\(encoded).firma"
}

private func assertNoSecrets(_ message: String) {
    #expect(!message.contains(secretCode))
    #expect(!message.contains(secretVerifier))
    #expect(!message.contains("ya29."))
    #expect(!message.contains("1//"))  // prefijo de refresh tokens de Google
}

@Suite("Login: errores específicos", .serialized)
struct LoginErrorTests {
    // MARK: /token con error HTTP + cuerpo OAuth

    @Test(arguments: [
        (400, "invalid_grant", "Bad Request", "authorization code was rejected"),
        (400, "invalid_request", "client_secret is missing.", "request is incomplete"),
        (401, "invalid_client", "The OAuth client was not found.", "must be a Desktop app client"),
        (400, "redirect_uri_mismatch", "Bad Request", "redirect URI is not allowed"),
        (403, "access_denied", "The user denied access.", "Access was denied"),
    ])
    func oauthErrorsAreShownVerbatimWithHint(status: Int, oauthError: String, description: String, hint: String) async {
        let body = #"{"error":"\#(oauthError)","error_description":"\#(description)"}"#
        do {
            _ = try await exchange(replying: .http(status: status, body: body))
            Issue.record("se esperaba error")
        } catch {
            #expect(error as? AuthError == .tokenEndpoint(status: status, error: oauthError, description: description))
            let message = LoginFailure.message(for: error, at: .exchangingCode)
            #expect(message.contains("HTTP \(status)"))
            #expect(message.contains(oauthError))  // tal cual
            #expect(message.contains(description))
            #expect(message.contains(hint))
            assertNoSecrets(message)
        }
    }

    @Test func httpErrorWithoutOAuthBodyKeepsStatus() async {
        await #expect(throws: AuthError.tokenEndpoint(status: 503, error: nil, description: nil)) {
            _ = try await exchange(replying: .http(status: 503, body: "<html>Service Unavailable</html>"))
        }
        let message = LoginFailure.message(
            for: AuthError.tokenEndpoint(status: 503, error: nil, description: nil), at: .exchangingCode)
        #expect(message == "Google rejected the sign-in (HTTP 503).")
    }

    // MARK: red y respuesta inválida

    @Test func networkErrorHasReadableDescription() async {
        do {
            _ = try await exchange(replying: .transport(.notConnectedToInternet))
            Issue.record("se esperaba error de red")
        } catch AuthError.network(let description) {
            #expect(description.contains("URLError -1009"))
            let message = LoginFailure.message(for: AuthError.network(description), at: .exchangingCode)
            #expect(message.hasPrefix("Network error while contacting Google: "))
            #expect(!message.contains("oauth2.googleapis.com/token?"))  // sin URL con query
            assertNoSecrets(message)
        } catch {
            Issue.record("error inesperado: \(error)")
        }
    }

    @Test func malformedSuccessBodyIsTyped() async {
        await #expect(throws: AuthError.malformedTokenResponse) {
            _ = try await exchange(replying: .http(status: 200, body: "not json"))
        }
        #expect(LoginFailure.message(for: AuthError.malformedTokenResponse, at: .exchangingCode)
            == "Google returned an unreadable token response.")
    }

    // MARK: identidad del canje

    @Test func identityRequiresRefreshTokenIdTokenAndEmail() throws {
        let withEmail = jwt(payload: #"{"email":"ada@example.com","sub":"1"}"#)
        let ok = TokenResponse(accessToken: "ya29.a", expiresIn: 3600, refreshToken: "1//r", idToken: withEmail, scope: nil)
        #expect(try ok.identity().email == "ada@example.com")
        #expect(!String(describing: try ok.identity()).contains("1//r"))

        let noRefresh = TokenResponse(accessToken: "ya29.a", expiresIn: 3600, refreshToken: nil, idToken: withEmail, scope: nil)
        #expect(throws: AuthError.missingRefreshToken) { try noRefresh.identity() }

        // Típico de pedir solo cloud-platform (sin openid/email): no hay id_token.
        let noIdToken = TokenResponse(accessToken: "ya29.a", expiresIn: 3600, refreshToken: "1//r", idToken: nil, scope: nil)
        #expect(throws: AuthError.missingIDToken) { try noIdToken.identity() }

        let noEmail = TokenResponse(
            accessToken: "ya29.a", expiresIn: 3600, refreshToken: "1//r",
            idToken: jwt(payload: #"{"sub":"1"}"#), scope: nil)
        #expect(throws: AuthError.idTokenWithoutEmail) { try noEmail.identity() }

        let garbage = TokenResponse(accessToken: "ya29.a", expiresIn: 3600, refreshToken: "1//r", idToken: "no-es-jwt", scope: nil)
        #expect(throws: AuthError.idTokenWithoutEmail) { try garbage.identity() }
    }

    @Test(arguments: [
        (AuthError.missingIDToken, "openid/email scope was not granted"),
        (.idTokenWithoutEmail, "does not include an email"),
        (.missingRefreshToken, "refresh token"),
    ])
    func identityErrorMessages(error: AuthError, expected: String) {
        let message = LoginFailure.message(for: error, at: .verifyingIdentity)
        #expect(message.contains(expected))
        assertNoSecrets(message)
    }

    // MARK: navegador / loopback

    @Test func loopbackTimeoutPointsAtLocalProxyOrFirewall() {
        let message = LoginFailure.message(for: AuthError.loopbackTimeout, at: .waitingForBrowser)
        #expect(message.contains("120 s"))
        #expect(message.contains("proxy"))
        #expect(message.contains("firewall"))
        #expect(message.contains("127.0.0.1"))
    }

    @Test func cancelledAndConsentKeepTheirMessages() {
        #expect(LoginFailure.message(for: AuthError.userCancelled, at: .waitingForBrowser) == "Sign-in was cancelled.")
        #expect(LoginFailure.message(for: AuthError.consentRequired, at: .waitingForBrowser)
            == "Google requires additional consent.")
    }

    @Test func invalidResponseDependsOnStage() {
        let browser = LoginFailure.message(for: AuthError.invalidResponse, at: .validatingCallback)
        let exchange = LoginFailure.message(for: AuthError.invalidResponse, at: .exchangingCode)
        #expect(browser.contains("browser"))
        #expect(exchange.contains("code exchange"))
        #expect(browser != exchange)
    }

    @Test func unknownErrorsNameStageAndTypeOnly() {
        struct OpaqueFailure: Error { let secret = "ya29.leak" }
        let message = LoginFailure.message(for: OpaqueFailure(), at: .savingCredentials)
        #expect(message.contains("savingCredentials"))
        #expect(message.contains("OpaqueFailure"))
        assertNoSecrets(message)
    }

    @Test func everyStageHasDistinctStatusText() {
        let texts = LoginStage.allCases.map(\.statusText)
        #expect(Set(texts).count == texts.count)
        #expect(texts.allSatisfy { !$0.isEmpty })
        #expect(LoginStage.waitingForBrowser.statusText.hasPrefix("Waiting for browser"))
        #expect(LoginStage.exchangingCode.statusText.hasPrefix("Exchanging"))
    }
}
