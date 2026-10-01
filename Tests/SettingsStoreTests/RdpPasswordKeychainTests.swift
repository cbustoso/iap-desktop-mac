// CBU-54: la contraseña Windows generada se guarda como `RdpPassword` en el
// Keychain de ámbito instancia (`KeychainSettingsStore`) y el usuario como
// `RdpUsername` en el store normal; mismo esquema de servicio/suite que el
// panel Settings y `KeychainWindowsCredentialVault` (App), con un servicio de test.
import Foundation
import Testing
@testable import SettingsStore

@Suite("RdpPassword en Keychain (CBU-54)", .serialized)
struct RdpPasswordKeychainTests {
    private struct Fixture {
        let component: String
        let secure: KeychainSettingsStore
        let plain: UserDefaultsSettingsStore
        let suite: String

        init() {
            // Igual que la App: persistencePath de instancia con "/" → ".".
            let path = SettingsScope.instance(project: "proj-\(UUID().uuidString.prefix(8))", zone: "z", instance: "win-1")
                .persistencePath.replacingOccurrences(of: "/", with: ".")
            component = path
            secure = KeychainSettingsStore(service: "com.iap-mac.settings.tests.secure.\(path)")
            suite = "com.iap-mac.settings.tests.\(path)"
            plain = UserDefaultsSettingsStore(suiteName: suite)
        }

        func save(username: String, password: String) throws {
            var secret = Setting(key: "RdpPassword", defaultValue: "")
            secret.value = password
            try secure.write(secret)
            var user = Setting(key: "RdpUsername", defaultValue: "")
            user.value = username
            try plain.write(user)
        }

        func load() throws -> (username: String, password: String)? {
            let password: Setting<String> = try secure.read(key: "RdpPassword", defaultValue: "")
            guard password.isSpecified else { return nil }
            let username: Setting<String> = try plain.read(key: "RdpUsername", defaultValue: "")
            return (username.value, password.value)
        }

        func tearDown() {
            try? secure.clear()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }

    @Test func instanceScopedServiceMatchesSettingsLayout() {
        let path = SettingsScope.instance(project: "p", zone: "z", instance: "win-1").persistencePath
        #expect(path.replacingOccurrences(of: "/", with: ".") == "p.vm-win-1")
    }

    @Test func roundTripsPasswordOnlyThroughKeychain() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        #expect(try fixture.load() == nil)

        try fixture.save(username: "ada", password: "Kc!round-trip-1")
        let loaded = try #require(try fixture.load())
        #expect(loaded.username == "ada")
        #expect(loaded.password == "Kc!round-trip-1")

        // El store normal (UserDefaults) solo tiene el usuario, nunca la contraseña.
        let defaults = try #require(UserDefaults(suiteName: fixture.suite))
        #expect(defaults.object(forKey: "RdpPassword") == nil)
        #expect(!defaults.dictionaryRepresentation().values.contains { value in
            let text = (value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? String(describing: value)
            return text.contains("Kc!round-trip-1")
        })
    }

    @Test func regenerateReplacesStoredPassword() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try fixture.save(username: "ada", password: "first-pw")
        try fixture.save(username: "ada", password: "second-pw")
        let loaded = try #require(try fixture.load())
        #expect(loaded.password == "second-pw")
    }

    @Test func passwordsAreIsolatedPerInstance() throws {
        let a = Fixture()
        let b = Fixture()
        defer {
            a.tearDown()
            b.tearDown()
        }
        try a.save(username: "ada", password: "pw-a")
        #expect(try b.load() == nil)
        #expect(try a.load()?.password == "pw-a")
    }
}
