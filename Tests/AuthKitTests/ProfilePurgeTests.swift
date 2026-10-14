// GH-74: `purge` no puede fiarse de UNA enumeración del Keychain: bajo
// escrituras concurrentes `kSecMatchLimitAll` omite entradas que existen.
// Keychain simulado (determinista) que reproduce esa omisión.
import Foundation
import Testing
@testable import AuthKit

/// Keychain en memoria: `hiddenReads` primeras enumeraciones omiten los
/// servicios de `hidden` (como la enumeración global bajo carga).
private final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Set<String>
    private var hidden: Set<String>
    private var hiddenReads: Int
    private var reappearing: String?
    private(set) var deletes: [String] = []
    private(set) var reads = 0
    var failure: ProfileError?

    init(_ services: Set<String>, hidden: Set<String> = [], hiddenReads: Int = 0, reappearing: String? = nil) {
        stored = services
        self.hidden = hidden
        self.hiddenReads = hiddenReads
        self.reappearing = reappearing
    }

    var remaining: Set<String> { lock.withLock { stored } }
    var deleted: [String] { lock.withLock { deletes } }
    var readCount: Int { lock.withLock { reads } }

    var access: KeychainNamespaceAccess {
        KeychainNamespaceAccess(
            services: { try self.services() },
            delete: { self.delete($0) },
            pause: {})
    }

    private func services() throws -> [String] {
        try lock.withLock {
            reads += 1
            if let failure { throw failure }
            if let reappearing { stored.insert(reappearing) }  // alguien sigue escribiendo
            guard hiddenReads > 0 else { return Array(stored) }
            hiddenReads -= 1
            return Array(stored.subtracting(hidden))
        }
    }

    private func delete(_ service: String) {
        lock.withLock {
            deletes.append(service)
            stored.remove(service)
        }
    }
}

@Suite("Perfiles: purge robusto ante enumeración incompleta (GH-74)")
struct ProfilePurgeTests {
    private let a = ProfileEnvironment(id: ProfileID(rawValue: "aaaa1111")!, migrationCompleted: true)
    private let b = ProfileEnvironment(id: ProfileID(rawValue: "bbbb2222")!, migrationCompleted: true)

    private var aSecret: String { a.settingsSecureService(component: "p.vm-win") }
    private var bSecret: String { b.settingsSecureService(component: "p.vm-win") }

    @Test func entriesMissedByTheFirstEnumerationAreStillDeleted() throws {
        // El caso del flake: las primeras lecturas no ven NADA de A (por debajo
        // de las confirmaciones exigidas; ver riesgo en `purgeKeychain`).
        let keychain = FakeKeychain(
            [a.authKeychainService, aSecret, b.authKeychainService, bSecret],
            hidden: [a.authKeychainService, aSecret], hiddenReads: ProfileEnvironment.purgeConfirmations - 1)
        try a.purge(keychain: keychain.access)
        #expect(keychain.remaining == [b.authKeychainService, bSecret])
    }

    @Test func knownAuthServiceIsDeletedWithoutRelyingOnEnumeration() throws {
        let keychain = FakeKeychain([a.authKeychainService], hidden: [a.authKeychainService], hiddenReads: .max)
        try a.purge(keychain: keychain.access)
        #expect(keychain.deleted.first == a.authKeychainService)
        #expect(keychain.remaining.isEmpty)
    }

    @Test func needsConsecutiveCleanReadsBeforeConfirming() throws {
        let keychain = FakeKeychain([aSecret], hidden: [aSecret], hiddenReads: 1)
        try a.purge(keychain: keychain.access)
        // lectura vacía (falsa) → lectura con aSecret → borrar → 3 limpias seguidas.
        #expect(keychain.remaining.isEmpty)
        #expect(keychain.readCount == 2 + ProfileEnvironment.purgeConfirmations)
    }

    @Test func neverDeletesOtherProfilesOrLegacyServices() throws {
        let legacy = [ProfileEnvironment.legacyAuthService, "com.iapdesktop.mac.settings.secure.p.vm-win"]
        let keychain = FakeKeychain(Set([aSecret, b.authKeychainService, bSecret] + legacy))
        try a.purge(keychain: keychain.access)
        #expect(keychain.remaining == Set([b.authKeychainService, bSecret] + legacy))
        #expect(keychain.deleted.allSatisfy { ProfileEnvironment.belongs($0, to: a.id) })
    }

    @Test func unconfirmedPurgeThrowsInsteadOfReportingSuccess() {
        let keychain = FakeKeychain([], reappearing: aSecret)
        #expect(throws: ProfileError.keychainPurgeIncomplete) { try a.purge(keychain: keychain.access) }
        #expect(keychain.readCount == ProfileEnvironment.purgeMaxPasses)
    }

    @Test func enumerationFailurePropagates() {
        let keychain = FakeKeychain([aSecret])
        keychain.failure = .keychainNamespaceFailure(-25_308)
        #expect(throws: ProfileError.keychainNamespaceFailure(-25_308)) { try a.purge(keychain: keychain.access) }
    }

    @Test func legacyProfileIsNeverPurged() throws {
        let legacy = ProfileEnvironment(id: .legacyDefault, migrationCompleted: false)
        let keychain = FakeKeychain([ProfileEnvironment.legacyAuthService])
        try legacy.purge(keychain: keychain.access)
        #expect(keychain.readCount == 0 && keychain.deleted.isEmpty)
    }
}
