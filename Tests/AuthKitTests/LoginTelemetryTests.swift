// CBU-28d: redacción de logs y clasificación de fallos de auto-carga/refresh.
import Foundation
import Testing
@testable import AuthKit

@Suite("Telemetría de login (REQ-AUTH-6)")
struct LoginTelemetryTests {
    @Test(arguments: [
        ("ada@example.com", "@example.com"),
        ("first.last+tag@sub.corp.example", "@sub.corp.example"),
        ("no-arroba", "<redacted>"),
        ("trailing@", "<redacted>"),
        ("", "<redacted>"),
        ("a@b@c.com", "@c.com"),
    ])
    func emailIsReducedToDomain(email: String, expected: String) {
        let redacted = LogRedaction.emailDomain(email)
        #expect(redacted == expected)
        if let local = email.split(separator: "@").first, !local.isEmpty, email.contains("@") {
            #expect(!redacted.contains(String(local)))  // nunca la parte local
        }
    }

    @Test(arguments: [
        (Int?.some(401), Int?.none, AuthError?.none, AutoLoadFailure.sessionRejected),
        (403, nil, nil, .permissionDenied),
        (500, nil, nil, .server(status: 500)),
        (nil, -1009, nil, .network("URLError -1009")),
        (nil, nil, .tokenExpired, .notSignedIn),
        (nil, nil, .tokenEndpoint(status: 400, error: "invalid_grant", description: "Token has been expired or revoked."), .sessionRejected),
        (nil, nil, .tokenEndpoint(status: 503, error: nil, description: nil), .tokenRefreshRejected(status: 503, oauthError: nil, description: nil)),
        (nil, nil, .tokenEndpoint(status: 400, error: "invalid_request", description: "client_secret is missing."),
         .tokenRefreshRejected(status: 400, oauthError: "invalid_request", description: "client_secret is missing.")),
        (nil, nil, .tokenEndpoint(status: 401, error: "invalid_client", description: "Unauthorized"),
         .tokenRefreshRejected(status: 401, oauthError: "invalid_client", description: "Unauthorized")),
        (nil, nil, .network("offline"), .network("offline")),
        (nil, nil, nil, .unknown("DecodingError")),
    ])
    func failuresAreClassified(status: Int?, urlCode: Int?, auth: AuthError?, expected: AutoLoadFailure) {
        #expect(AutoLoadFailure(httpStatus: status, urlErrorCode: urlCode, authError: auth, typeName: "DecodingError") == expected)
    }

    @Test func serviceDisabledMapsToApiNotEnabled() {
        let failure = AutoLoadFailure(
            httpStatus: 403, reason: "SERVICE_DISABLED",
            urlErrorCode: nil, authError: nil, typeName: "X")
        #expect(failure == .apiNotEnabled)
        #expect(failure.logCause.contains("api-disabled"))
        #expect(failure.userNote.contains("Add project"))
    }

    @Test func permissionDeniedWithoutReasonStays() {
        let failure = AutoLoadFailure(
            httpStatus: 403, reason: nil,
            urlErrorCode: nil, authError: nil, typeName: "X")
        #expect(failure == .permissionDenied)
    }

    @Test func refreshDescriptionReachesLog() {
        let failure = AutoLoadFailure(
            httpStatus: nil, reason: nil, urlErrorCode: nil,
            authError: .tokenEndpoint(
                status: 400, error: "invalid_request",
                description: "client_secret is missing."),
            typeName: "X")
        #expect(failure.logCause.contains("desc=client_secret is missing."))
    }

    @Test func causesAndNotesNeverCarrySecrets() {
        let all: [AutoLoadFailure] = [
            .notSignedIn, .sessionRejected, .permissionDenied, .apiNotEnabled, .network("URLError -1009"),
            .server(status: 500), .unknown("DecodingError"),
            .tokenRefreshRejected(status: 400, oauthError: "invalid_request", description: "client_secret is missing."),
        ]
        for failure in all {
            for text in [failure.logCause, failure.userNote] {
                #expect(!text.isEmpty)
                #expect(!text.contains("ya29."))
                #expect(!text.contains("1//"))
                #expect(!text.contains("@"))  // ni emails
            }
        }
        #expect(AutoLoadFailure.permissionDenied.logCause.contains("http=403"))
        #expect(AutoLoadFailure.sessionRejected.userNote.contains("401"))
        // Regresión (log real): un refresh 400 debe llevar el código OAuth y su descripción.
        #expect(AutoLoadFailure.tokenRefreshRejected(status: 400, oauthError: "invalid_request", description: "client_secret is missing.").logCause
            == "cause=token_refresh http=400 oauth_error=invalid_request desc=client_secret is missing.")
    }
}
