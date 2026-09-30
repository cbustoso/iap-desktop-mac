// AuthKit T-AUTH-1 tests (trazables a REQ-AUTH-1/2/3/6).
import Testing
import Foundation
@testable import AuthKit

private func makeCredential(
    email: String = "test-\(UUID().uuidString)@example.com",
    issuer: OidcIssuer = .gaia
) -> OfflineCredential {
    OfflineCredential(
        issuer: issuer,
        email: email,
        refreshToken: "refresh-\(UUID().uuidString)",
        idToken: "id-\(UUID().uuidString)",
        scopes: ["https://www.googleapis.com/auth/cloud-platform"]
    )
}

@Suite("KeychainStore")
struct KeychainStoreTests {
    let store = KeychainStore(service: "com.iap-mac.auth.test")

    @Test func roundTripSaveLoadDelete() throws {
        let credential = makeCredential()
        try store.save(credential)
        let loaded = try store.load(issuer: credential.issuer, email: credential.email)
        #expect(loaded == credential)
        #expect(try store.delete(issuer: credential.issuer, email: credential.email) == true)
        #expect(try store.load(issuer: credential.issuer, email: credential.email) == nil)
    }

    @Test func loadMissingReturnsNil() throws {
        #expect(try store.load(issuer: .gaia, email: "missing@example.com") == nil)
    }

    @Test func multiIssuerIsolation() throws {
        let gaia = makeCredential(issuer: .gaia)
        let sts = OfflineCredential(
            issuer: .sts, email: gaia.email, refreshToken: "r", idToken: "i", scopes: [])
        try store.save(gaia)
        try store.save(sts)
        #expect(try store.load(issuer: .gaia, email: gaia.email) == gaia)
        #expect(try store.load(issuer: .sts, email: gaia.email) == sts)
        try store.delete(issuer: .gaia, email: gaia.email)
        try store.delete(issuer: .sts, email: gaia.email)
    }
}

@Suite("CredentialFacade")
struct CredentialFacadeTests {
    @Test func authorizeEmitsAndServesToken() async throws {
        let facade = CredentialFacade(store: KeychainStore(service: "com.iap-mac.auth.test"))
        let credential = makeCredential()
        let stream = await facade.reauthorized()
        let task = Task { for await _ in stream { break } }
        try await facade.authorize(
            credential, accessToken: "at", expiresAt: Date().addingTimeInterval(60))
        await task.value  // se completa solo al recibir el primer evento Reauthorized
        #expect(try await facade.validAccessToken() == "at")
        #expect(await facade.currentEmail == credential.email)
        await facade.revoke()
    }

    @Test func spliceKeepsActorAndDiscardsOldIssuer() async throws {
        let store = KeychainStore(service: "com.iap-mac.auth.test")
        let facade = CredentialFacade(store: store)
        let email = "splice-\(UUID().uuidString)@example.com"
        let gaia = OfflineCredential(
            issuer: .gaia, email: email, refreshToken: "r1", idToken: "i1", scopes: [])
        try await facade.authorize(gaia, accessToken: "at", expiresAt: Date().addingTimeInterval(60))
        let sts = OfflineCredential(
            issuer: .sts, email: email, refreshToken: "r2", idToken: "i2", scopes: [])
        try await facade.splice(sts)  // cambio Gaia→STS descarta la anterior
        #expect(try store.load(issuer: .gaia, email: email) == nil)
        #expect(await facade.isWorkforceSession == true)
        // Sin access token tras splice hasta el refresh (T-AUTH-3)
        await #expect(throws: AuthError.tokenExpired) { try await facade.validAccessToken() }
        await facade.revoke()
    }

    @Test func revokeClearsAll() async throws {
        let facade = CredentialFacade(store: KeychainStore(service: "com.iap-mac.auth.test"))
        let credential = makeCredential()
        try await facade.authorize(
            credential, accessToken: "at", expiresAt: Date().addingTimeInterval(60))
        await facade.revoke()
        #expect(await facade.currentEmail == nil)
        await #expect(throws: AuthError.tokenExpired) { try await facade.validAccessToken() }
    }
}

@Suite("Secret redaction (REQ-AUTH-6)")
struct RedactionTests {
    @Test func debugDescriptionNeverContainsTokens() {
        let credential = makeCredential()
        let description = credential.debugDescription
        #expect(!description.contains(credential.refreshToken))
        #expect(!description.contains(credential.idToken))
        #expect(description.contains(credential.email))
    }
}
