import Foundation
import Testing
@testable import AuthKit

@Suite("ClientIDStore")
struct ClientIDStoreTests {
    @Test func acceptsAndNormalizesGoogleClientID() throws {
        try withDefaults { defaults in
            let store = ClientIDStore(defaults: defaults, environment: [:])
            let clientID = "123-example.apps.googleusercontent.com"

            let saved = try store.save("  \(clientID)\n")
            let resolved = try store.resolve()
            #expect(saved == clientID)
            #expect(resolved == clientID)
        }
    }

    @Test func rejectsInvalidClientID() throws {
        try withDefaults { defaults in
            let store = ClientIDStore(defaults: defaults, environment: [:])

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
                environment: [ClientIDStore.environmentKey: environment])
            let resolved = try configuredStore.resolve()
            #expect(resolved == environment)

            let missingStore = ClientIDStore(defaults: defaults, environment: [:])
            #expect(throws: AuthError.userCancelled) {
                try missingStore.resolve()
            }
        }
    }

    @Test func descriptionsRedactClientID() throws {
        try withDefaults { defaults in
            let clientID = "secret-client.apps.googleusercontent.com"
            let store = ClientIDStore(defaults: defaults, environment: [:])
            try store.save(clientID)

            let description = String(describing: store)
            let debugDescription = String(reflecting: store)

            #expect(!description.contains(clientID))
            #expect(!debugDescription.contains(clientID))
            #expect(description.contains("<redacted>"))
            #expect(debugDescription.contains("<redacted>"))
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ClientIDStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
