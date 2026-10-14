// GH-72 (specs/multitenant): perfiles — índice no sensible, namespacing y
// aislamiento real de Keychain entre perfiles, `Reauthorized` sin fugas,
// registro de sesiones por perfil y migración del perfil único legado.
import Foundation
import Security
import Testing
@testable import AuthKit

private func credential(_ email: String, refresh: String = "1//refresh-SECRET") -> OfflineCredential {
    OfflineCredential(
        issuer: .gaia, email: email, refreshToken: refresh, idToken: "id-token-SECRET",
        scopes: ["https://www.googleapis.com/auth/cloud-platform"], issuedAt: Date(timeIntervalSince1970: 1_000))
}

/// Defaults aislados por test (nunca `.standard`).
private final class TestDefaults: @unchecked Sendable {
    let name = "com.iapdesktop.mac.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    private let lock = NSLock()
    private var suites: [String] = []

    init() { defaults = UserDefaults(suiteName: name)! }

    /// Suites "del perfil" redirigidas a un prefijo de test.
    func suite(_ suite: String) -> UserDefaults? {
        let name = "\(self.name).\(suite)"
        lock.withLock { suites.append(name) }
        return UserDefaults(suiteName: name)
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: name)
        for suite in lock.withLock({ suites }) { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }
}

private func deleteKeychain(service: String) {
    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
}

@Suite("Perfiles: índice (T-MT-1)")
struct ProfileStoreTests {
    @Test func profileIDValidation() {
        #expect(ProfileID(rawValue: "legacy-default-profile") == .legacyDefault)
        #expect(ProfileID(rawValue: "") == nil)
        #expect(ProfileID(rawValue: "a/b") == nil)
        #expect(ProfileID(rawValue: "a.b") == nil)  // se usa dentro de nombres de servicio
        #expect(ProfileID(rawValue: String(repeating: "a", count: 65)) == nil)
        let a = ProfileID.generate()
        let b = ProfileID.generate()
        #expect(a != b)
        #expect(ProfileID(rawValue: a.rawValue) == a)
    }

    @Test func roundTripUpsertRemove() throws {
        let test = TestDefaults()
        defer { test.tearDown() }
        let store = ProfileStore(defaults: test.defaults)
        #expect(store.list().isEmpty)
        let id = ProfileID.generate()
        try store.upsert(ProfileDescriptor(id: id, displayName: "Cliente A"))
        try store.upsert(ProfileDescriptor(id: .legacyDefault, displayName: "Perfil principal"))
        #expect(store.list().map(\.displayName) == ["Cliente A", "Perfil principal"])

        var renamed = try #require(store.descriptor(for: id))
        renamed.displayName = "Cliente A (prod)"
        try store.upsert(renamed)
        #expect(store.list().count == 2)
        #expect(store.descriptor(for: id)?.displayName == "Cliente A (prod)")

        try store.remove(id)
        #expect(store.list().map(\.id) == [.legacyDefault])
        #expect(throws: ProfileError.notFound(id)) { try store.remove(id) }
    }

    @Test func sameEmailDifferentProfilesDoNotCollide() throws {
        let test = TestDefaults()
        defer { test.tearDown() }
        let store = ProfileStore(defaults: test.defaults)
        let account = ProfileDescriptor.redactedAccount(issuer: .gaia, account: "ada@example.com")
        let inHouse = ProfileDescriptor(id: .generate(), displayName: "Interno", issuer: .gaia, redactedAccount: account)
        let crossOrg = ProfileDescriptor(id: .generate(), displayName: "Cross-org", issuer: .gaia, redactedAccount: account)
        try store.upsert(inHouse)
        try store.upsert(crossOrg)
        #expect(store.list() == [inHouse, crossOrg])  // no se deduplica por email
        #expect(ProfileStore.keychainService(for: inHouse.id, suffix: "auth")
            != ProfileStore.keychainService(for: crossOrg.id, suffix: "auth"))
    }

    @Test func indexNeverStoresFullEmailOrTokens() throws {
        let test = TestDefaults()
        defer { test.tearDown() }
        let store = ProfileStore(defaults: test.defaults)
        let gaia = ProfileDescriptor.redactedAccount(issuer: .gaia, account: "ada.lovelace@example.com")
        let principal = "principal://iam.googleapis.com/locations/global/workforcePools/corp-pool/subject/ada%40corp.example"
        let sts = ProfileDescriptor.redactedAccount(issuer: .sts, account: principal)
        #expect(gaia == "a…@example.com")
        #expect(sts == "corp-pool: @corp.example")
        #expect(ProfileDescriptor.redactedAccount(issuer: .sts, account: "garbage") == "<redacted>")
        try store.upsert(ProfileDescriptor(id: .generate(), displayName: "G", issuer: .gaia, redactedAccount: gaia, lastUsedAt: Date()))
        try store.upsert(ProfileDescriptor(id: .generate(), displayName: "W", issuer: .sts, redactedAccount: sts))
        let raw = String(decoding: try #require(test.defaults.data(forKey: ProfileStore.defaultsKey)), as: UTF8.self)
        for secret in ["ada.lovelace@", "ada@corp", "principal://", "refresh", "token"] {
            #expect(!raw.contains(secret), "\(secret)")
        }
    }

    @Test func unreadableIndexIsEmptyNotACrash() {
        let test = TestDefaults()
        defer { test.tearDown() }
        test.defaults.set(Data("not json".utf8), forKey: ProfileStore.defaultsKey)
        #expect(ProfileStore(defaults: test.defaults).list().isEmpty)
    }
}

@Suite("Perfiles: namespacing (T-MT-2)")
struct ProfileEnvironmentTests {
    @Test func namespacedNamesCarryTheProfileID() {
        let id = ProfileID(rawValue: "1234-abcd")!
        #expect(ProfileStore.keychainService(for: id, suffix: "auth") == "com.iap-mac.auth.profile.1234-abcd")
        #expect(ProfileStore.userDefaultsSuite(for: id, component: "explorer") == "com.iapdesktop.mac.settings.profile.1234-abcd.explorer")
        let env = ProfileEnvironment(id: id, migrationCompleted: true)
        #expect(!env.usesLegacyLocations)
        #expect(env.authKeychainService == "com.iap-mac.auth.profile.1234-abcd")
        #expect(env.clientIDSuite == "com.iapdesktop.mac.settings.profile.1234-abcd.oauth")
        #expect(env.settingsSecureService(component: "p.vm-a") == "com.iapdesktop.mac.settings.secure.profile.1234-abcd.p.vm-a")
        #expect(env.settingsSuite(component: "p.vm-a") == "com.iapdesktop.mac.settings.profile.1234-abcd.p.vm-a")
    }

    @Test func legacyProfileUsesOldLocationsOnlyUntilMigrated() {
        let pending = ProfileEnvironment(id: .legacyDefault, migrationCompleted: false)
        #expect(pending.usesLegacyLocations)
        #expect(pending.authKeychainService == "com.iap-mac.auth")
        #expect(pending.clientIDSuite == nil)  // .standard
        #expect(pending.explorerSuite == nil)
        let migrated = ProfileEnvironment(id: .legacyDefault, migrationCompleted: true)
        #expect(!migrated.usesLegacyLocations)
        #expect(migrated.authKeychainService == "com.iap-mac.auth.profile.legacy-default-profile")
        // Settings del legado: nombres de siempre (no se migran, no se pierden).
        #expect(migrated.settingsSecureService(component: "p.vm-a") == "com.iapdesktop.mac.settings.secure.p.vm-a")
    }

    @Test func serviceOwnershipHasNoPrefixCollisions() {
        let a = ProfileID(rawValue: "abc")!
        #expect(ProfileEnvironment.belongs("com.iap-mac.auth.profile.abc", to: a))
        #expect(ProfileEnvironment.belongs("com.iapdesktop.mac.settings.secure.profile.abc.p.vm-x", to: a))
        #expect(!ProfileEnvironment.belongs("com.iap-mac.auth.profile.abcd", to: a))
        #expect(!ProfileEnvironment.belongs("com.iapdesktop.mac.settings.secure.profile.abcd.p", to: a))
        #expect(!ProfileEnvironment.belongs("com.iap-mac.auth", to: a))
    }
}

@Suite("Perfiles: aislamiento de Keychain y sesión (T-MT-2/6)", .serialized)
struct ProfileIsolationTests {
    @Test func facadesOfTwoProfilesShareNoKeychainEntries() async throws {
        let a = ProfileEnvironment(id: .generate(), migrationCompleted: true)
        let b = ProfileEnvironment(id: .generate(), migrationCompleted: true)
        defer { try? a.purge(); try? b.purge() }
        let facadeA = CredentialFacade(store: a.keychainStore())
        let facadeB = CredentialFacade(store: b.keychainStore())
        // Mismo email en ambos perfiles (client OAuth distinto): no colisionan.
        try await facadeA.authorize(credential("ada@example.com", refresh: "refresh-A"), accessToken: "tok-A", expiresAt: .distantFuture)
        #expect(try b.keychainStore().accounts().isEmpty)
        try await facadeB.authorize(credential("ada@example.com", refresh: "refresh-B"), accessToken: "tok-B", expiresAt: .distantFuture)
        #expect(try a.keychainStore().load(issuer: .gaia, email: "ada@example.com")?.refreshToken == "refresh-A")
        #expect(try b.keychainStore().load(issuer: .gaia, email: "ada@example.com")?.refreshToken == "refresh-B")
        #expect(try await facadeA.validAccessToken() == "tok-A")
        #expect(try await facadeB.validAccessToken() == "tok-B")
    }

    @Test func purgingOneProfileLeavesTheOtherIntact() throws {
        let a = ProfileEnvironment(id: .generate(), migrationCompleted: true)
        let b = ProfileEnvironment(id: .generate(), migrationCompleted: true)
        defer { try? b.purge() }
        try a.keychainStore().save(credential("ada@example.com"))
        try b.keychainStore().save(credential("ada@example.com"))
        // Contraseña RDP / setting sensible del perfil A (servicio namespaced).
        for env in [a, b] {
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: env.settingsSecureService(component: "p.vm-win"),
                kSecAttrAccount as String: "RdpPassword", kSecValueData as String: Data("pw".utf8),
            ]
            #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        }
        a.explorerDefaults()?.set(["proj-a"], forKey: ProfileEnvironment.knownProjectsKey)
        b.explorerDefaults()?.set(["proj-b"], forKey: ProfileEnvironment.knownProjectsKey)

        try a.purge()

        #expect(try a.keychainStore().accounts().isEmpty)
        #expect(try b.keychainStore().accounts().count == 1)
        func hasSecret(_ env: ProfileEnvironment) -> Bool {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: env.settingsSecureService(component: "p.vm-win"),
            ]
            return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        }
        #expect(!hasSecret(a))
        #expect(hasSecret(b))
        #expect(b.explorerDefaults()?.stringArray(forKey: ProfileEnvironment.knownProjectsKey) == ["proj-b"])
        #expect(UserDefaults(suiteName: a.explorerSuite!)?.stringArray(forKey: ProfileEnvironment.knownProjectsKey) == nil)
    }

    @Test func purgeNeverTouchesLegacyLocations() throws {
        let legacy = ProfileEnvironment(id: .legacyDefault, migrationCompleted: false)
        try legacy.purge()  // no-op: el legado sin migrar no se borra por esta vía
    }

    @Test func revokingOneProfileNeverReauthorizesTheOther() async throws {
        let a = ProfileEnvironment(id: .generate(), migrationCompleted: true)
        let b = ProfileEnvironment(id: .generate(), migrationCompleted: true)
        defer { try? a.purge(); try? b.purge() }
        let facadeA = CredentialFacade(store: a.keychainStore())
        let facadeB = CredentialFacade(store: b.keychainStore())
        try await facadeA.authorize(credential("a@example.com"), accessToken: "tok-A", expiresAt: .distantFuture)
        try await facadeB.authorize(credential("b@example.com"), accessToken: "tok-B", expiresAt: .distantFuture)

        let eventsA = Counter()
        let eventsB = Counter()
        let streamA = await facadeA.reauthorized()
        let streamB = await facadeB.reauthorized()
        let listenA = Task { for await _ in streamA { eventsA.increment() } }
        let listenB = Task { for await _ in streamB { eventsB.increment() } }

        await facadeA.revoke()  // logout del perfil A
        try await Task.sleep(for: .milliseconds(100))
        #expect(eventsA.value == 1)
        #expect(eventsB.value == 0)  // nunca llega al otro perfil
        #expect(await facadeA.currentEmail == nil)
        #expect(await facadeB.currentEmail == "b@example.com")
        #expect(try await facadeB.validAccessToken() == "tok-B")
        listenA.cancel()
        listenB.cancel()
    }
}

/// `@unchecked Sendable`: bajo `lock`.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Doble de `ProfileSession`: sesiones SSH simuladas por perfil.
@MainActor
private final class FakeProfileSession {
    let id: ProfileID
    var sshSessions: Set<String>
    private(set) var tornDown = false
    init(id: ProfileID, sessions: Set<String>) {
        self.id = id
        sshSessions = sessions
    }
    func teardown() {
        sshSessions.removeAll()
        tornDown = true
    }
}

@Suite("Perfiles: sesiones por perfil (T-MT-3/4)")
@MainActor
struct ProfileSessionRegistryTests {
    @Test func activatingAnOpenProfileReturnsTheSameSession() {
        let registry = ProfileSessionRegistry<FakeProfileSession>()
        let id = ProfileID.generate()
        var made = 0
        let first = registry.activate(id) { made += 1; return FakeProfileSession(id: id, sessions: ["p/z/web"]) }
        let again = registry.activate(id) { made += 1; return FakeProfileSession(id: id, sessions: []) }
        #expect(first.created)
        #expect(!again.created)
        #expect(first.session === again.session)  // identidad, no solo valor
        #expect(made == 1)
        #expect(again.session.sshSessions == ["p/z/web"])  // conexiones intactas
    }

    @Test func twoProfilesGetIndependentSessions() {
        let registry = ProfileSessionRegistry<FakeProfileSession>()
        let a = ProfileID.generate()
        let b = ProfileID.generate()
        let sessionA = registry.activate(a) { FakeProfileSession(id: a, sessions: ["p/z/web"]) }.session
        let sessionB = registry.activate(b) { FakeProfileSession(id: b, sessions: ["p/z/web"]) }.session
        #expect(sessionA !== sessionB)
        #expect(registry.openIDs == [a, b])
        #expect(registry.mostRecent === sessionB)
        // Cambiar el foco varias veces no recrea ni toca nada.
        for _ in 0..<3 {
            _ = registry.activate(a) { FakeProfileSession(id: a, sessions: []) }
            _ = registry.activate(b) { FakeProfileSession(id: b, sessions: []) }
        }
        #expect(registry.session(for: a) === sessionA)
        #expect(registry.session(for: b) === sessionB)
        #expect(sessionA.sshSessions == ["p/z/web"])
        #expect(sessionB.sshSessions == ["p/z/web"])
    }

    @Test func closingOneProfileOnlyCleansItsOwnSessions() throws {
        let registry = ProfileSessionRegistry<FakeProfileSession>()
        let a = ProfileID.generate()
        let b = ProfileID.generate()
        let sessionA = registry.activate(a) { FakeProfileSession(id: a, sessions: ["p/z/web", "p/z/db"]) }.session
        let sessionB = registry.activate(b) { FakeProfileSession(id: b, sessions: ["q/z/app"]) }.session

        let closed = try #require(registry.remove(a))
        closed.teardown()

        #expect(closed === sessionA)
        #expect(sessionA.tornDown && sessionA.sshSessions.isEmpty)
        #expect(!sessionB.tornDown)
        #expect(sessionB.sshSessions == ["q/z/app"])
        #expect(registry.session(for: a) == nil)
        #expect(registry.session(for: b) === sessionB)
        #expect(registry.openIDs == [b])
        #expect(registry.remove(a) == nil)  // idempotente
    }
}

/// Vault que guarda pero no devuelve lo guardado (fallo en la verificación).
private struct BrokenVault: CredentialVault {
    func accounts() throws -> [(issuer: OidcIssuer, email: String)] { [] }
    func load(issuer: OidcIssuer, email: String) throws -> OfflineCredential? { nil }
    func save(_ credential: OfflineCredential) throws -> Bool { true }
}

@Suite("Perfiles: migración legada (T-MT-7)", .serialized)
struct ProfileMigratorTests {
    private struct Rig {
        let test = TestDefaults()
        let legacyService = "com.iap-mac.auth.tests.legacy.\(UUID().uuidString)"
        let targetService = "com.iap-mac.auth.tests.target.\(UUID().uuidString)"
        var legacy: KeychainStore { KeychainStore(service: legacyService) }
        var target: KeychainStore { KeychainStore(service: targetService) }
        var store: ProfileStore { ProfileStore(defaults: test.defaults) }

        func migrator(targetVault: (any CredentialVault)? = nil) -> ProfileMigrator {
            let test = self.test
            return ProfileMigrator(
                defaults: test.defaults, store: store, legacyVault: legacy, targetVault: targetVault ?? target,
                targetDefaults: { test.suite($0) })
        }

        func tearDown() {
            deleteKeychain(service: legacyService)
            deleteKeychain(service: targetService)
            test.tearDown()
        }
    }

    @Test func fullLegacyStateMigratesVerifiedAndExactlyOnce() throws {
        let rig = Rig()
        defer { rig.tearDown() }
        try rig.legacy.save(credential("ada@example.com"))
        rig.test.defaults.set(["proj-1", "proj-2"], forKey: ProfileEnvironment.knownProjectsKey)
        rig.test.defaults.set("1234-abc.apps.googleusercontent.com", forKey: ClientIDStore.defaultsKey)

        let outcome = rig.migrator().migrateLegacySingleProfileIfNeeded(now: Date(timeIntervalSince1970: 5))
        #expect(outcome == .migrated(accounts: 1, projects: 2, clientIDOverride: true))
        #expect(rig.migrator().isCompleted)

        // Copiado a las ubicaciones namespaced del perfil legado…
        #expect(try rig.target.load(issuer: .gaia, email: "ada@example.com") == credential("ada@example.com"))
        let env = ProfileEnvironment(id: .legacyDefault, migrationCompleted: true)
        #expect(rig.test.suite(env.explorerSuite!)?.stringArray(forKey: ProfileEnvironment.knownProjectsKey) == ["proj-1", "proj-2"])
        #expect(rig.test.suite(env.clientIDSuite!)?.string(forKey: ClientIDStore.defaultsKey) == "1234-abc.apps.googleusercontent.com")
        // …sin borrar lo legado (copia, no movimiento).
        #expect(try rig.legacy.accounts().count == 1)
        #expect(rig.test.defaults.stringArray(forKey: ProfileEnvironment.knownProjectsKey) == ["proj-1", "proj-2"])
        // Visible en el selector, con la cuenta enmascarada.
        let descriptor = try #require(rig.store.descriptor(for: .legacyDefault))
        #expect(descriptor.displayName == "Perfil principal")
        #expect(descriptor.issuer == .gaia)
        #expect(descriptor.redactedAccount == "a…@example.com")
        #expect(descriptor.lastUsedAt == Date(timeIntervalSince1970: 5))

        // Segunda vez: no-op.
        try rig.legacy.save(credential("other@example.com"))
        #expect(rig.migrator().migrateLegacySingleProfileIfNeeded() == .alreadyMigrated)
        #expect(try rig.target.accounts().count == 1)
    }

    @Test func emptyLegacyStateMigratesToPendingSignInProfile() throws {
        let rig = Rig()
        defer { rig.tearDown() }
        #expect(rig.migrator().migrateLegacySingleProfileIfNeeded() == .migratedEmpty)
        #expect(rig.migrator().isCompleted)
        let descriptor = try #require(rig.store.descriptor(for: .legacyDefault))
        #expect(!descriptor.isSignedIn)
        #expect(descriptor.redactedAccount == nil)
    }

    @Test func verificationFailureMarksNothingAndKeepsLegacyData() throws {
        let rig = Rig()
        defer { rig.tearDown() }
        try rig.legacy.save(credential("ada@example.com"))
        rig.test.defaults.set(["proj-1"], forKey: ProfileEnvironment.knownProjectsKey)

        let outcome = rig.migrator(targetVault: BrokenVault()).migrateLegacySingleProfileIfNeeded()
        #expect(outcome == .failed(.migrationVerificationFailed))
        #expect(!rig.migrator().isCompleted)
        #expect(rig.store.descriptor(for: .legacyDefault) == nil)
        // Cero pérdida: todo lo legado sigue intacto y la app sigue en modo legado.
        #expect(try rig.legacy.load(issuer: .gaia, email: "ada@example.com") == credential("ada@example.com"))
        #expect(rig.test.defaults.stringArray(forKey: ProfileEnvironment.knownProjectsKey) == ["proj-1"])
        #expect(ProfileEnvironment(id: .legacyDefault, migrationCompleted: rig.migrator().isCompleted).usesLegacyLocations)

        // El siguiente arranque, con el Keychain sano, migra.
        #expect(rig.migrator().migrateLegacySingleProfileIfNeeded() == .migrated(accounts: 1, projects: 1, clientIDOverride: false))
    }
}
