// CBU-28e: refresh sin client ID → error local (sin llamar a Google),
// traza con build/prefijo de client (sin secretos) y causas nuevas.
import Foundation
import Testing
@testable import AuthKit

/// Cuenta peticiones HTTP: verifica que no se llama a la red.
private final class CountingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"invalid_request","error_description":"Could not determine client ID from request."}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func countingSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CountingProtocol.self]
    return URLSession(configuration: configuration)
}

@Suite("Diagnóstico de refresh (CBU-28e)", .serialized)
struct RefreshDiagnosticsTests {
    @Test(arguments: ["", "   ", "\n"])
    func emptyClientIDFailsLocallyWithoutCallingGoogle(clientID: String) async {
        CountingProtocol.requests = 0
        let client = TokenClient(clientID: clientID, clientSecret: "GOCSPX-x", session: countingSession())
        await #expect(throws: AuthError.clientNotConfigured) {
            _ = try await client.refresh(refreshToken: "1//refresh")
        }
        await #expect(throws: AuthError.clientNotConfigured) {
            _ = try await client.exchange(
                code: "4/code", verifier: "v", redirectURI: URL(string: "http://127.0.0.1:1/authorize")!)
        }
        #expect(CountingProtocol.requests == 0)  // ni una petición con client_id vacío
    }

    @Test func configuredClientStillReachesTheNetwork() async {
        CountingProtocol.requests = 0
        let client = TokenClient(
            clientID: "123456789012-placeholder.apps.googleusercontent.com", session: countingSession())
        await #expect(throws: AuthError.self) { _ = try await client.refresh(refreshToken: "1//refresh") }
        #expect(CountingProtocol.requests == 1)
    }

    @Test(arguments: [
        (String?.some("0.1"), true, "build=0.1/app"),
        ("0.1", false, "build=0.1/bare"),
        (nil, false, "build=dev/bare"),
        ("  ", true, "build=dev/app"),
    ])
    func buildLabelDistinguishesBundleFromBareBinary(version: String?, isApp: Bool, expected: String) {
        #expect(BuildInfo.describe(version: version, isAppBundle: isApp) == expected)
    }

    @Test func clientIDPrefixIsShortAndNeverTheFullID() {
        let full = "123456789012-placeholder.apps.googleusercontent.com"
        let prefix = LogRedaction.clientIDPrefix(full)
        #expect(prefix == "12345678…")
        #expect(!prefix.contains("apps.googleusercontent.com"))
        #expect(LogRedaction.clientIDPrefix("") == "<empty>")
        #expect(LogRedaction.clientIDPrefix("  ") == "<empty>")
    }

    @Test func newCausesAreClassified() {
        let otherClient = AutoLoadFailure(
            httpStatus: nil, urlErrorCode: nil,
            authError: .tokenEndpoint(status: 400, error: "unauthorized_client", description: "Unauthorized"),
            typeName: "AuthError")
        #expect(otherClient == .sessionFromOtherClient)
        #expect(otherClient.userNote.contains("vuelve a iniciar sesión"))

        let noClient = AutoLoadFailure(
            httpStatus: nil, urlErrorCode: nil, authError: .clientNotConfigured, typeName: "AuthError")
        #expect(noClient == .clientNotConfigured)
        #expect(noClient.logCause == "cause=no_client_id")
        #expect(noClient.userNote.contains("secrets.env"))
    }

    @Test func loginMessageForMissingClientIsActionable() {
        let message = LoginFailure.message(for: AuthError.clientNotConfigured, at: .exchangingCode)
        #expect(message.contains("GOOGLE_OAUTH_CLIENT_ID"))
        #expect(message.contains("GOOGLE_OAUTH_CLIENT_SECRET"))
        #expect(message.contains("secrets.env"))
    }
}
