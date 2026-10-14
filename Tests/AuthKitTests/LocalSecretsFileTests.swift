// GH-80: sin secretos embebidos. El client OAuth sale del entorno o de un
// fichero local opcional fuera del repo. Solo placeholders en los tests.
import Foundation
import Testing
@testable import AuthKit

private let placeholderID = "123456789012-placeholder.apps.googleusercontent.com"
private let placeholderSecret = "placeholder-client-secret"

/// Directorio temporal con `secrets.env` y permisos controlados.
private func secretsFile(_ contents: String, mode: Int = 0o600) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("iap-secrets-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("secrets.env")
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    return url
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

private func isolatedDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "LocalSecretsFileTests.\(UUID().uuidString)"))
}

@Suite("Client OAuth sin secretos embebidos (GH-80)")
struct LocalSecretsFileTests {
    @Test func parsesOnlyAllowedKeysWithQuotesExportAndComments() {
        let values = LocalSecretsFile.parse("""
            # client OAuth de desarrollo
            export GOOGLE_OAUTH_CLIENT_ID="\(placeholderID)"
            GOOGLE_OAUTH_CLIENT_SECRET = '\(placeholderSecret)'
            HOME=/tmp/ignored
            GOOGLE_OAUTH_CLIENT_ID_EXTRA=nope
            broken line without equals

            """)
        #expect(values == [
            ClientIDStore.environmentKey: placeholderID,
            ClientIDStore.secretEnvironmentKey: placeholderSecret,
        ])
        #expect(LocalSecretsFile.parse("GOOGLE_OAUTH_CLIENT_SECRET=value # nota")[ClientIDStore.secretEnvironmentKey] == "value")
        #expect(LocalSecretsFile.parse("GOOGLE_OAUTH_CLIENT_SECRET=").isEmpty)
    }

    @Test func missingFileIsSimplyIgnored() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)/secrets.env")
        #expect(LocalSecretsFile.load(from: url).isEmpty)
        #expect(LocalSecretsFile.load(from: FileManager.default.temporaryDirectory).isEmpty)  // directorio, no fichero
    }

    @Test func fileWritableByOthersIsRejected() throws {
        let url = try secretsFile("GOOGLE_OAUTH_CLIENT_ID=\(placeholderID)\n", mode: 0o622)
        defer { cleanup(url) }
        #expect(LocalSecretsFile.load(from: url).isEmpty)
    }

    @Test func defaultLocationFollowsXDGOrHomeConfig() {
        #expect(LocalSecretsFile.defaultURL(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"]).path
            == "/tmp/xdg/iap-desktop-mac/secrets.env")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(LocalSecretsFile.defaultURL(environment: [:]).path == "\(home)/.config/iap-desktop-mac/secrets.env")
        #expect(LocalSecretsFile.defaultURL(environment: ["XDG_CONFIG_HOME": "relative"]).path
            == "\(home)/.config/iap-desktop-mac/secrets.env")
    }

    @Test func signInWorksWithEnvironmentOnlyAndNoBundle() throws {
        // Lo que hace un `swift run`/binario sin Info.plist, o el .app con placeholders.
        for bundle in [nil, ClientIDStore.bundlePlaceholder] {
            let store = ClientIDStore(
                defaults: try isolatedDefaults(), bundledClientID: bundle,
                bundledClientSecret: bundle == nil ? nil : ClientIDStore.secretBundlePlaceholder,
                environment: [ClientIDStore.environmentKey: placeholderID, ClientIDStore.secretEnvironmentKey: placeholderSecret],
                secretsFile: nil)
            #expect(try store.resolve() == placeholderID)
            #expect(try store.clientIDForSignIn(fieldValue: "") == placeholderID)
            #expect(store.clientSecret() == placeholderSecret)
            #expect(store.missingConfiguration == nil)
        }
    }

    @Test func secretsFileConfiguresSignInAndEnvironmentWins() throws {
        let url = try secretsFile("""
            GOOGLE_OAUTH_CLIENT_ID=\(placeholderID)
            GOOGLE_OAUTH_CLIENT_SECRET=\(placeholderSecret)
            """)
        defer { cleanup(url) }
        let fromFile = ClientIDStore(defaults: try isolatedDefaults(), bundledClientID: nil, environment: [:], secretsFile: url)
        #expect(try fromFile.resolve() == placeholderID)
        #expect(fromFile.clientSecret() == placeholderSecret)
        #expect(fromFile.missingConfiguration == nil)

        let otherID = "999999999999-other.apps.googleusercontent.com"
        let envWins = ClientIDStore(
            defaults: try isolatedDefaults(), bundledClientID: nil,
            environment: [ClientIDStore.environmentKey: otherID], secretsFile: url)
        #expect(try envWins.resolve() == otherID)
        #expect(envWins.clientSecret() == placeholderSecret)  // clave a clave: el secret sigue del fichero
    }

    @Test func secretsFromFileNeverAppearInDescriptions() throws {
        let url = try secretsFile("GOOGLE_OAUTH_CLIENT_ID=\(placeholderID)\nGOOGLE_OAUTH_CLIENT_SECRET=\(placeholderSecret)\n")
        defer { cleanup(url) }
        let store = ClientIDStore(defaults: try isolatedDefaults(), bundledClientID: nil, environment: [:], secretsFile: url)
        for text in [store.description, store.debugDescription, String(describing: store)] {
            #expect(!text.contains(placeholderSecret))
            #expect(!text.contains(placeholderID))
        }
    }

    @Test func missingBothGivesActionableMessageInsteadOfCrashing() throws {
        let store = ClientIDStore(
            defaults: try isolatedDefaults(), bundledClientID: ClientIDStore.bundlePlaceholder,
            bundledClientSecret: ClientIDStore.secretBundlePlaceholder, environment: [:], secretsFile: nil)
        #expect(!store.isConfigured)
        #expect(throws: AuthError.userCancelled) { try store.resolve() }
        #expect(store.clientSecret() == nil)
        #expect(store.missingConfiguration == .clientID)
        let message = try #require(store.missingConfiguration?.message)
        for hint in ["GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET", "secrets.env", "docs/usage.md"] {
            #expect(message.contains(hint))
        }
        #expect(LoginFailure.message(for: AuthError.clientNotConfigured, at: .preparing).contains("secrets.env"))
    }

    @Test func missingOnlySecretIsReportedSeparately() throws {
        let store = ClientIDStore(
            defaults: try isolatedDefaults(), bundledClientID: nil,
            environment: [ClientIDStore.environmentKey: placeholderID], secretsFile: nil)
        #expect(store.missingConfiguration == .clientSecret)
        #expect(store.missingConfiguration?.message.contains("GOOGLE_OAUTH_CLIENT_SECRET") == true)
    }
}
