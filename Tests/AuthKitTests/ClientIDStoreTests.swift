import Foundation
import Testing
@testable import AuthKit

@Suite("ClientIDStore")
struct ClientIDStoreTests {
    @Test func acceptsAndNormalizesGoogleClientID() throws {
        try withDefaults { defaults in
            let store = ClientIDStore(defaults: defaults, bundledClientID: nil, environment: [:])
            let clientID = "123-example.apps.googleusercontent.com"

            let saved = try store.save("  \(clientID)\n")
            let resolved = try store.resolve()
            #expect(saved == clientID)
            #expect(resolved == clientID)
        }
    }

    @Test func rejectsInvalidClientID() throws {
        try withDefaults { defaults in
            let store = ClientIDStore(defaults: defaults, bundledClientID: nil, environment: [:])

            #expect(throws: AuthError.invalidResponse) {
                try store.save("not-a-google-client-id")
            }
        }
    }

    @Test func storedValueTakesPrecedenceOverEnvironment() throws {
        try withDefaults { defaults in
            let stored = "stored.apps.googleusercontent.com"
            let environment = "environment.apps.googleusercontent.com"
            let store = ClientIDStore(
                defaults: defaults,
                bundledClientID: nil,
                environment: [ClientIDStore.environmentKey: environment])

            try store.save(stored)

            let resolved = try store.resolve()
            #expect(resolved == stored)
        }
    }

    @Test func fallsBackToEnvironmentAndThrowsWhenMissing() throws {
        try withDefaults { defaults in
            let environment = "environment.apps.googleusercontent.com"
            let configuredStore = ClientIDStore(
                defaults: defaults,
                bundledClientID: nil,
                environment: [ClientIDStore.environmentKey: environment])
            let resolved = try configuredStore.resolve()
            #expect(resolved == environment)

            let missingStore = ClientIDStore(defaults: defaults, bundledClientID: nil, environment: [:])
            #expect(throws: AuthError.userCancelled) {
                try missingStore.resolve()
            }
        }
    }

    @Test func descriptionsRedactClientID() throws {
        try withDefaults { defaults in
            let clientID = "secret-client.apps.googleusercontent.com"
            let store = ClientIDStore(defaults: defaults, bundledClientID: nil, environment: [:])
            try store.save(clientID)

            let description = String(describing: store)
            let debugDescription = String(reflecting: store)

            #expect(!description.contains(clientID))
            #expect(!debugDescription.contains(clientID))
            #expect(description.contains("<redacted>"))
            #expect(debugDescription.contains("<redacted>"))
        }
    }

    // MARK: - CBU-36: default embebido en Info.plist

    private static let override = "override.apps.googleusercontent.com"
    private static let bundled = "bundled.apps.googleusercontent.com"
    private static let fromEnvironment = "environment.apps.googleusercontent.com"

    @Test func resolutionOrderIsOverrideThenBundleThenEnvironment() throws {
        try withDefaults { defaults in
            let environment = [ClientIDStore.environmentKey: Self.fromEnvironment]
            let store = ClientIDStore(
                defaults: defaults, bundledClientID: Self.bundled, environment: environment)
            let value1 = try store.resolve()
            #expect(value1 == Self.bundled)  // bundle > entorno

            try store.save(Self.override)
            let value2 = try store.resolve()
            #expect(value2 == Self.override)  // override > bundle

            let noBundle = ClientIDStore(
                defaults: defaults, bundledClientID: nil, environment: environment)
            noBundle.clearOverride()
            let value3 = try noBundle.resolve()
            #expect(value3 == Self.fromEnvironment)
        }
    }

    @Test(arguments: [ClientIDStore.bundlePlaceholder, "", "  \n", "  __OAUTH_CLIENT_ID__ "])
    func placeholderOrEmptyBundleValueCountsAsMissing(bundleValue: String) throws {
        try withDefaults { defaults in
            let withEnvironment = ClientIDStore(
                defaults: defaults, bundledClientID: bundleValue,
                environment: [ClientIDStore.environmentKey: Self.fromEnvironment])
            let value4 = try withEnvironment.resolve()
            #expect(value4 == Self.fromEnvironment)

            let nothing = ClientIDStore(defaults: defaults, bundledClientID: bundleValue, environment: [:])
            #expect(!nothing.isConfigured)
            #expect(throws: AuthError.userCancelled) { try nothing.resolve() }
        }
    }

    @Test func malformedBundleValueIsReportedNotSkipped() throws {
        // Error del maintainer: mejor fallar visible que caer al entorno sin avisar.
        try withDefaults { defaults in
            let store = ClientIDStore(
                defaults: defaults, bundledClientID: "not-a-client-id",
                environment: [ClientIDStore.environmentKey: Self.fromEnvironment])
            #expect(throws: AuthError.invalidResponse) { try store.resolve() }
        }
    }

    @Test func signInWithDefaultDoesNotPinItAsOverride() throws {
        try withDefaults { defaults in
            let store = ClientIDStore(defaults: defaults, bundledClientID: Self.bundled, environment: [:])
            // Campo vacío o con el mismo valor ya resuelto: login directo sin guardar.
            let value5 = try store.clientIDForSignIn(fieldValue: "")
            #expect(value5 == Self.bundled)
            let value6 = try store.clientIDForSignIn(fieldValue: " \(Self.bundled) ")
            #expect(value6 == Self.bundled)
            #expect(defaults.string(forKey: ClientIDStore.defaultsKey) == nil)

            // Un maintainer actualiza el default: se aplica porque no se fijó override.
            let updated = ClientIDStore(
                defaults: defaults, bundledClientID: "updated.apps.googleusercontent.com", environment: [:])
            let value7 = try updated.resolve()
            #expect(value7 == "updated.apps.googleusercontent.com")
        }
    }

    @Test func signInWithDifferentValueSavesOverride() throws {
        try withDefaults { defaults in
            let store = ClientIDStore(defaults: defaults, bundledClientID: Self.bundled, environment: [:])
            let value8 = try store.clientIDForSignIn(fieldValue: Self.override)
            #expect(value8 == Self.override)
            #expect(defaults.string(forKey: ClientIDStore.defaultsKey) == Self.override)
            #expect(throws: AuthError.invalidResponse) {
                try store.clientIDForSignIn(fieldValue: "garbage")
            }
        }
    }

    @Test func signInWithoutAnyClientIDThrowsMissing() throws {
        try withDefaults { defaults in
            let store = ClientIDStore(defaults: defaults, bundledClientID: nil, environment: [:])
            #expect(throws: AuthError.userCancelled) { try store.clientIDForSignIn(fieldValue: "") }
        }
    }

    @Test func clearOverrideFallsBackToBundledDefault() throws {
        try withDefaults { defaults in
            let store = ClientIDStore(defaults: defaults, bundledClientID: Self.bundled, environment: [:])
            try store.save(Self.override)
            store.clearOverride()
            let value9 = try store.resolve()
            #expect(value9 == Self.bundled)
        }
    }

    @Test func cloudConsoleLinkPointsToCredentials() {
        let url = ClientIDStore.cloudConsoleCredentialsURL
        #expect(url.scheme == "https")
        #expect(url.host == "console.cloud.google.com")
        #expect(url.path == "/apis/credentials")
    }

    @Test func shippedInfoPlistDeclaresClientIDKey() throws {
        // La clave debe existir con el placeholder documentado o con un
        // client ID bien formado (lo que ponga el maintainer).
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let dictionary = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let value = try #require(dictionary[ClientIDStore.infoPlistKey] as? String)
        #expect(value == ClientIDStore.bundlePlaceholder || value.hasSuffix(".apps.googleusercontent.com"))
    }

    @Test func shippedInfoPlistSecretIsDocumented() throws {
        // El dueño aportó su client secret para que el login funcione sin
        // setup (CBU-45). Si existe, debe resolverse vía clientSecret() y
        // NUNCA aparecer en descripciones/logs (ver test de redacción).
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let dictionary = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        if let secret = dictionary[ClientIDStore.secretPlistKey] as? String {
            let store = ClientIDStore(
                bundledClientID: nil, bundledClientSecret: secret, environment: [:])
            #expect(store.clientSecret() == secret)
            #expect(!store.description.contains(secret))
            #expect(!store.debugDescription.contains(secret))
        }
    }

    @Test func clientSecretResolvesFromBundleThenEnvironment() throws {
        try withDefaults { defaults in
            let fromBundle = ClientIDStore(
                defaults: defaults,
                bundledClientID: nil,
                bundledClientSecret: "  bundled-secret  ",
                environment: [ClientIDStore.secretEnvironmentKey: "env-secret"])
            #expect(fromBundle.clientSecret() == "bundled-secret")
            let fromEnv = ClientIDStore(
                defaults: defaults,
                bundledClientID: nil,
                bundledClientSecret: "   ",
                environment: [ClientIDStore.secretEnvironmentKey: "env-secret"])
            #expect(fromEnv.clientSecret() == "env-secret")
            let missing = ClientIDStore(
                defaults: defaults,
                bundledClientID: nil,
                bundledClientSecret: nil,
                environment: [:])
            #expect(missing.clientSecret() == nil)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ClientIDStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
