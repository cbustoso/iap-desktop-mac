// GH-88: `CloudProvider` en `ProfileDescriptor`. Retrocompatibilidad del
// índice (v1 sin `provider` → Google), upgrade idempotente del esquema,
// índice ilegible sin pérdida, y namespace Keychain `.azure` por perfil.
import Foundation
import Security
import Testing
@testable import AuthKit

/// Defaults aislados por test (nunca `.standard`).
private struct IsolatedDefaults {
    let name = "com.iapdesktop.mac.tests.cloud.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func tearDown() { UserDefaults.standard.removePersistentDomain(forName: name) }
}

/// Índice tal como lo escribía el build anterior a GH-88 (JSONEncoder por
/// defecto: fechas en segundos desde 2001). Sin `provider` ni `homeTenantID`.
private let v1Index = #"""
[{"id":"legacy-default-profile","displayName":"Perfil principal","issuer":"https:\/\/oauth2.googleapis.com\/","redactedAccount":"a…@example.com","lastUsedAt":782000000},
 {"id":"0f9e8d7c-aaaa","displayName":"Cliente WIF","issuer":"https:\/\/sts.googleapis.com\/","redactedAccount":"corp-pool: @corp.example"},
 {"id":"pending-1","displayName":"Sin sesión"}]
"""#

@Suite("Perfiles: CloudProvider (GH-88)")
struct CloudProviderTests {
    @Test func v1IndexDecodesAsGoogleWithEveryFieldIntact() throws {
        let test = IsolatedDefaults()
        defer { test.tearDown() }
        test.defaults.set(Data(v1Index.utf8), forKey: ProfileStore.defaultsKey)
        let profiles = ProfileStore(defaults: test.defaults).list()
        #expect(profiles.count == 3)
        #expect(profiles.allSatisfy { $0.provider == .google && $0.homeTenantID == nil })
        #expect(profiles[0].id == .legacyDefault)
        #expect(profiles[0].issuer == .gaia)
        #expect(profiles[0].redactedAccount == "a…@example.com")
        #expect(profiles[0].lastUsedAt == Date(timeIntervalSinceReferenceDate: 782_000_000))
        #expect(profiles[1].issuer == .sts)
        #expect(profiles.map(\.isSignedIn) == [true, true, false])
    }

    @Test func upgradeMakesProviderExplicitAndIsIdempotent() throws {
        let test = IsolatedDefaults()
        defer { test.tearDown() }
        test.defaults.set(Data(v1Index.utf8), forKey: ProfileStore.defaultsKey)
        let store = ProfileStore(defaults: test.defaults)
        let before = store.list()

        #expect(store.upgradeIndexIfNeeded() == .upgraded(profiles: 3))
        #expect(test.defaults.integer(forKey: ProfileStore.schemaKey) == ProfileStore.currentSchema)
        #expect(store.list() == before)
        let raw = String(decoding: try #require(test.defaults.data(forKey: ProfileStore.defaultsKey)), as: UTF8.self)
        #expect(raw.components(separatedBy: #""provider":"google""#).count == 4)

        #expect(store.upgradeIndexIfNeeded() == .alreadyCurrent)
        #expect(store.list() == before)
    }

    @Test func upgradeWithoutIndexOnlyMarksTheSchema() {
        let test = IsolatedDefaults()
        defer { test.tearDown() }
        let store = ProfileStore(defaults: test.defaults)
        #expect(store.upgradeIndexIfNeeded() == .upgraded(profiles: 0))
        #expect(test.defaults.data(forKey: ProfileStore.defaultsKey) == nil)
        #expect(store.upgradeIndexIfNeeded() == .alreadyCurrent)
    }

    @Test func unreadableIndexIsNeitherRewrittenNorMarked() {
        let test = IsolatedDefaults()
        defer { test.tearDown() }
        let garbage = Data("not json".utf8)
        test.defaults.set(garbage, forKey: ProfileStore.defaultsKey)
        let store = ProfileStore(defaults: test.defaults)
        #expect(store.upgradeIndexIfNeeded() == .skippedUnreadable)
        #expect(test.defaults.data(forKey: ProfileStore.defaultsKey) == garbage)
        #expect(test.defaults.object(forKey: ProfileStore.schemaKey) == nil)
    }

    @Test func unknownProviderFromANewerBuildIsBackedUpBeforeOverwrite() throws {
        let test = IsolatedDefaults()
        defer { test.tearDown() }
        let newer = Data(#"[{"id":"x1","displayName":"Otra nube","provider":"aws"}]"#.utf8)
        test.defaults.set(newer, forKey: ProfileStore.defaultsKey)
        let store = ProfileStore(defaults: test.defaults)
        #expect(store.list().isEmpty)  // no se adivina la nube
        try store.upsert(ProfileDescriptor(id: .generate(), displayName: "Nuevo"))
        #expect(test.defaults.data(forKey: ProfileStore.unreadableBackupKey) == newer)
        #expect(store.list().map(\.displayName) == ["Nuevo"])
    }

    @Test func azureDescriptorRoundTripsAndSignsInByTenant() throws {
        let test = IsolatedDefaults()
        defer { test.tearDown() }
        let store = ProfileStore(defaults: test.defaults)
        var azure = ProfileDescriptor(id: .generate(), displayName: "Contoso", provider: .azure)
        #expect(!azure.isSignedIn)
        azure.homeTenantID = "72f988bf-86f1-41af-91ab-2d7cd011db47"
        azure.redactedAccount = ProfileDescriptor.redactedAccount(azureUsername: "ada@contoso.com")
        #expect(azure.isSignedIn)
        // Un `issuer` Google no hace "signed in" a un perfil Azure.
        #expect(!ProfileDescriptor(id: .generate(), displayName: "x", provider: .azure, issuer: .gaia).isSignedIn)
        try store.upsert(azure)
        try store.upsert(ProfileDescriptor(id: .generate(), displayName: "GCP", issuer: .gaia))
        #expect(store.list().map(\.provider) == [.azure, .google])
        #expect(store.descriptor(for: azure.id) == azure)
        let raw = String(decoding: try #require(test.defaults.data(forKey: ProfileStore.defaultsKey)), as: UTF8.self)
        #expect(!raw.contains("ada@"))
    }

    @Test func azureAccountRedaction() {
        #expect(ProfileDescriptor.redactedAccount(azureUsername: "ada.lovelace@contoso.com") == "a…@contoso.com")
        #expect(ProfileDescriptor.redactedAccount(azureUsername: "ada_corp.com#EXT#@fabrikam.onmicrosoft.com")
            == "a…@fabrikam.onmicrosoft.com")
        #expect(ProfileDescriptor.redactedAccount(azureUsername: "no-at-sign") == "<redacted>")
    }

    @Test func azureKeychainServiceIsNamespacedPerProfile() {
        let a = ProfileEnvironment(id: ProfileID(rawValue: "aaaa1111")!, migrationCompleted: true)
        let b = ProfileEnvironment(id: ProfileID(rawValue: "aaaa11112")!, migrationCompleted: true)
        #expect(a.azureKeychainService == "com.iap-mac.azure.profile.aaaa1111")
        #expect(ProfileEnvironment.belongs(a.azureKeychainService, to: a.id))
        #expect(!ProfileEnvironment.belongs(b.azureKeychainService, to: a.id))
        // El legado también usa nombre namespaced: no hay Azure "de antes".
        let legacy = ProfileEnvironment(id: .legacyDefault, migrationCompleted: false)
        #expect(legacy.azureKeychainService == "com.iap-mac.azure.profile.legacy-default-profile")
    }

    @Test func purgeDeletesTheAzureServiceDirectlyAndSparesOtherProfiles() throws {
        let a = ProfileEnvironment(id: ProfileID(rawValue: "aaaa1111")!, migrationCompleted: true)
        let b = ProfileEnvironment(id: ProfileID(rawValue: "bbbb2222")!, migrationCompleted: true)
        let keychain = MemoryKeychain([a.authKeychainService, a.azureKeychainService, b.azureKeychainService])
        try a.purge(keychain: keychain.access)
        #expect(keychain.deleted.prefix(2) == [a.authKeychainService, a.azureKeychainService])
        #expect(keychain.remaining == [b.azureKeychainService])
    }

    @Test func googleCredentialsSurviveTheIndexUpgrade() throws {
        let test = IsolatedDefaults()
        defer { test.tearDown() }
        let id = ProfileID.generate()
        let env = ProfileEnvironment(id: id, migrationCompleted: true)
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: env.authKeychainService] as CFDictionary) }
        let credential = OfflineCredential(
            issuer: .gaia, email: "ada@example.com", refreshToken: "1//refresh-SECRET", idToken: "id-SECRET",
            scopes: [AuthorizeURL.cloudScope], issuedAt: Date(timeIntervalSince1970: 1_000))
        try env.keychainStore().save(credential)
        let legacyEntry = #"[{"id":"\#(id.rawValue)","displayName":"G","issuer":"https:\/\/oauth2.googleapis.com\/"}]"#
        test.defaults.set(Data(legacyEntry.utf8), forKey: ProfileStore.defaultsKey)

        #expect(ProfileStore(defaults: test.defaults).upgradeIndexIfNeeded() == .upgraded(profiles: 1))
        // Mismo servicio Keychain de siempre: la credencial se sigue leyendo.
        #expect(env.authKeychainService == "com.iap-mac.auth.profile.\(id.rawValue)")
        #expect(try env.keychainStore().load(issuer: .gaia, email: "ada@example.com") == credential)
    }
}

/// Keychain en memoria para `purge` (determinista, sin el Keychain real).
private final class MemoryKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Set<String>
    private var deletes: [String] = []

    init(_ services: Set<String>) { stored = services }

    var remaining: Set<String> { lock.withLock { stored } }
    var deleted: [String] { lock.withLock { deletes } }

    var access: KeychainNamespaceAccess {
        KeychainNamespaceAccess(
            services: { self.lock.withLock { Array(self.stored) } },
            delete: { service in
                self.lock.withLock {
                    self.deletes.append(service)
                    self.stored.remove(service)
                }
            },
            pause: {})
    }
}
