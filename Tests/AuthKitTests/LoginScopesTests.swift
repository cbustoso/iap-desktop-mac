// CBU-46: el login pide openid + email + cloud-platform desde el primer intento.
import Foundation
import Testing
@testable import AuthKit

@Suite("Scopes del login")
struct LoginScopesTests {
    private func scopeParameter(of authorize: AuthorizeURL) throws -> String? {
        let request = authorize.build(
            redirectURI: URL(string: "http://127.0.0.1:50123/authorize")!,
            pkce: PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        return components.queryItems?.first { $0.name == "scope" }?.value
    }

    @Test func signInRequestsOpenIDEmailAndCloudByDefault() throws {
        #expect(AuthorizeURL.signInScopes == [
            "openid",
            "https://www.googleapis.com/auth/userinfo.email",
            "https://www.googleapis.com/auth/cloud-platform",
        ])
        let scope = try scopeParameter(of: AuthorizeURL(clientID: "123-abc.apps.googleusercontent.com"))
        #expect(scope == "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/cloud-platform")
    }

    @Test func authorizeURLStillRequestsOfflineAccessAndConsent() throws {
        let request = AuthorizeURL(clientID: "c").build(
            redirectURI: URL(string: "http://127.0.0.1:1/authorize")!, pkce: PKCE())
        let items = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "access_type", value: "offline")))  // refresh_token
        #expect(items.contains(URLQueryItem(name: "prompt", value: "consent")))
    }

    @Test func cloudPlatformMustBeGranted() {
        let all = "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/cloud-platform"
        #expect(AuthorizeURL.missingScopes(granted: all).isEmpty)
        // Consentimiento granular: el usuario desmarcó Cloud.
        let withoutCloud = "openid https://www.googleapis.com/auth/userinfo.email"
        #expect(AuthorizeURL.missingScopes(granted: withoutCloud) == [AuthorizeURL.cloudScope])
        // Sin campo `scope` en la respuesta no se puede saber.
        #expect(AuthorizeURL.missingScopes(granted: nil).isEmpty)
    }

    /// Regresión del bug: un canje sin id_token sigue fallando con el mensaje
    /// específico (no con "Sign-in failed").
    @Test func exchangeWithoutIDTokenStillFailsSpecifically() {
        let response = TokenResponse(
            accessToken: "ya29.a", expiresIn: 3600, refreshToken: "1//r", idToken: nil,
            scope: "https://www.googleapis.com/auth/cloud-platform")
        #expect(throws: AuthError.missingIDToken) { try response.identity() }
        let message = LoginFailure.message(for: AuthError.missingIDToken, at: .verifyingIdentity)
        #expect(message.contains("openid/email scope was not granted"))
    }
}
