// T-SSH-7 (CBU-43): TOFU persistente, rechazo tipado ante cambio de host key
// (sin autenticar) y redacción de material criptográfico en logs.
import CryptoKit
import Foundation
import IAPTestSupport
import NIOSSH
import Testing
@testable import SSHKit

/// Huellas en memoria. `@unchecked`: estado bajo `lock`.
private final class MemoryHostKeyStore: HostKeyStore, @unchecked Sendable {
    struct Broken: Error {}
    private let lock = NSLock()
    private var entries: [HostKeyIdentity: HostKeyFingerprint] = [:]
    var failReads = false
    var failWrites = false

    var all: [HostKeyIdentity: HostKeyFingerprint] { lock.withLock { entries } }

    func fingerprint(for identity: HostKeyIdentity) throws -> HostKeyFingerprint? {
        try lock.withLock {
            if failReads { throw Broken() }
            return entries[identity]
        }
    }

    func save(_ fingerprint: HostKeyFingerprint, for identity: HostKeyIdentity) throws {
        try lock.withLock {
            if failWrites { throw Broken() }
            entries[identity] = fingerprint
        }
    }

    func remove(_ identity: HostKeyIdentity) throws {
        lock.withLock { _ = entries.removeValue(forKey: identity) }
    }
}

/// Registro de resultados (lo que iría a OSLog). `@unchecked`: bajo `lock`.
private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(HostKeyIdentity, HostKeyVerifier.Outcome)] = []
    var outcomes: [HostKeyVerifier.Outcome] { lock.withLock { entries.map(\.1) } }
    var lines: [String] { lock.withLock { entries.map { HostKeyVerifier.logLine(identity: $0.0, outcome: $0.1) } } }
    func record(_ identity: HostKeyIdentity, _ outcome: HostKeyVerifier.Outcome) {
        lock.withLock { entries.append((identity, outcome)) }
    }
}

private func newHostKey() -> NIOSSHPublicKey {
    NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
}

private func base64Blob(_ key: NIOSSHPublicKey) -> String {
    String(String(openSSHPublicKey: key).split(separator: " ")[1])
}

private let vm = HostKeyIdentity(SshTarget(project: "p", zone: "z", instance: "web-01"))

@Suite("HostKeyVerifier TOFU (CBU-43)")
struct HostKeyVerifierTests {
    @Test func fingerprintMatchesOpenSSH() throws {
        // Vector de `ssh-keygen -lf` (llave pública de prueba, sin privada).
        let key = try NIOSSHPublicKey(
            openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvSn2vrhVB22Ok/40XMHrYaf2QcOxLyWbesAEEQMeJR")
        #expect(HostKeyFingerprint(key).value == "SHA256:FfYANHdwYMhYUsBsLqBoiRZmOESz8pL8BNhs+IexR8g")
    }

    @Test func identityIsInstancePlusRemotePort() {
        #expect(vm.description == "p/z/web-01:22")
        let rdp = HostKeyIdentity(SshTarget(project: "p", zone: "z", instance: "web-01", port: 2222))
        #expect(rdp != vm)
    }

    @Test func firstUseAcceptsAndStoresThenMatches() {
        let store = MemoryHostKeyStore()
        let log = LogRecorder()
        let verifier = HostKeyVerifier(store: store, record: log.record)
        let key = newHostKey()

        #expect(verifier.verify(key, for: vm) == nil)
        #expect(store.all[vm] == HostKeyFingerprint(key))
        #expect(verifier.verify(key, for: vm) == nil)
        #expect(log.outcomes == [.trustedOnFirstUse, .matched])
    }

    @Test func changedKeyIsRejectedWithTypedErrorAndStoreUntouched() throws {
        let store = MemoryHostKeyStore()
        let verifier = HostKeyVerifier(store: store, record: { _, _ in })
        let original = newHostKey()
        let impostor = newHostKey()
        _ = verifier.verify(original, for: vm)

        let error = try #require(verifier.verify(impostor, for: vm))
        guard case .changed(let change) = error else {
            Issue.record("se esperaba .changed")
            return
        }
        #expect(change.identity == vm)
        #expect(change.expected == HostKeyFingerprint(original))
        #expect(change.presented == HostKeyFingerprint(impostor))
        #expect(store.all[vm] == HostKeyFingerprint(original))  // no se sobrescribe
        // Sigue rechazando hasta confirmación explícita.
        #expect(verifier.verify(impostor, for: vm) != nil)
        #expect(!verifier.policy(for: vm).accepts(impostor))
    }

    @Test func explicitTrustAcceptsNewKeyAndForgetResets() throws {
        let store = MemoryHostKeyStore()
        let verifier = HostKeyVerifier(store: store, record: { _, _ in })
        let original = newHostKey()
        let replacement = newHostKey()
        _ = verifier.verify(original, for: vm)
        guard case .changed(let change)? = verifier.verify(replacement, for: vm) else {
            Issue.record("se esperaba .changed")
            return
        }
        try verifier.trust(change)
        #expect(verifier.verify(replacement, for: vm) == nil)
        #expect(verifier.verify(original, for: vm) != nil)

        try verifier.forget(vm)
        #expect(store.all[vm] == nil)
    }

    @Test func storeFailuresFailClosed() {
        let unreadable = MemoryHostKeyStore()
        unreadable.failReads = true
        #expect(HostKeyVerifier(store: unreadable, record: { _, _ in }).verify(newHostKey(), for: vm)
            == .storeUnavailable(vm))

        let unwritable = MemoryHostKeyStore()
        unwritable.failWrites = true
        #expect(HostKeyVerifier(store: unwritable, record: { _, _ in }).verify(newHostKey(), for: vm)
            == .storeUnavailable(vm))
    }

    @Test func pinnedPolicyKeepsLegacyError() {
        let key = newHostKey()
        #expect(SSHHostKeyPolicy.pinned(key).evaluate(newHostKey()) as? SSHTransportError == .hostKeyRejected)
        #expect(SSHHostKeyPolicy.pinned(key).evaluate(key) == nil)
    }

    @Test func connectionFailureShowsBothFingerprintsToUser() throws {
        let verifier = HostKeyVerifier(store: MemoryHostKeyStore(), record: { _, _ in })
        let original = newHostKey()
        let impostor = newHostKey()
        _ = verifier.verify(original, for: vm)
        let error = try #require(verifier.verify(impostor, for: vm))
        let failure = ConnectionFailure(error)
        #expect(failure.message.contains(HostKeyFingerprint(original).value))
        #expect(failure.message.contains(HostKeyFingerprint(impostor).value))
        #expect(failure.message.contains("bloqueada"))
    }
}

@Suite("HostKeyVerifier: conexión real (CBU-43)", .serialized, .timeLimit(.minutes(1)))
struct HostKeyVerifierSessionTests {
    @Test func changedHostKeyRejectsBeforeAuthenticating() async throws {
        let userKey = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let first = try await MockSSHServer.start(username: "ada", authorizedKey: userKey.publicKey)
        let verifier = HostKeyVerifier(store: MemoryHostKeyStore(), record: { _, _ in })

        // Primera conexión: TOFU acepta y la sesión se abre.
        let session = try await SshSession.connect(
            host: "127.0.0.1", port: first.port, username: "ada", privateKey: userKey,
            hostKeyPolicy: verifier.policy(for: vm))
        await session.close()
        await first.shutdown()

        // Misma VM lógica, otra host key (VM recreada o MITM). La llave del
        // usuario SÍ está autorizada: si conectara, no habría error.
        let second = try await MockSSHServer.start(username: "ada", authorizedKey: userKey.publicKey)
        defer { Task { await second.shutdown() } }
        do {
            let unexpected = try await SshSession.connect(
                host: "127.0.0.1", port: second.port, username: "ada", privateKey: userKey,
                hostKeyPolicy: verifier.policy(for: vm), timeout: .seconds(10))
            await unexpected.close()
            Issue.record("la conexión debió rechazarse")
        } catch let error as HostKeyVerificationError {
            guard case .changed(let change) = error else {
                Issue.record("se esperaba .changed, llegó \(error)")
                return
            }
            #expect(change.presented == HostKeyFingerprint(second.hostKey))
            #expect(second.observed.shellRequested == false)
        }
    }
}

@Suite("KeychainHostKeyStore (CBU-43)", .serialized)
struct KeychainHostKeyStoreTests {
    @Test func roundTripPerHostAndPort() throws {
        let store = KeychainHostKeyStore(service: "com.iapdesktop.mac.ssh.known-hosts.tests.\(UUID().uuidString)")
        defer { try? store.removeAll() }
        let other = HostKeyIdentity(host: vm.host, port: 2222)
        let fingerprint = HostKeyFingerprint(newHostKey())

        #expect(try store.fingerprint(for: vm) == nil)
        try store.save(fingerprint, for: vm)
        #expect(try store.fingerprint(for: vm) == fingerprint)
        #expect(try store.fingerprint(for: other) == nil)  // por host+puerto

        let replacement = HostKeyFingerprint(newHostKey())
        try store.save(replacement, for: vm)
        #expect(try store.fingerprint(for: vm) == replacement)

        try store.remove(vm)
        #expect(try store.fingerprint(for: vm) == nil)
    }

    @Test func verifierPersistsAcrossInstances() throws {
        let service = "com.iapdesktop.mac.ssh.known-hosts.tests.\(UUID().uuidString)"
        defer { try? KeychainHostKeyStore(service: service).removeAll() }
        let key = newHostKey()
        #expect(HostKeyVerifier(store: KeychainHostKeyStore(service: service), record: { _, _ in }).verify(key, for: vm) == nil)
        // "Reinicio de la App": verificador nuevo, mismo Keychain.
        let restarted = HostKeyVerifier(store: KeychainHostKeyStore(service: service), record: { _, _ in })
        #expect(restarted.verify(key, for: vm) == nil)
        #expect(restarted.verify(newHostKey(), for: vm) != nil)
    }
}

@Suite("Redacción de material criptográfico (CBU-43)")
struct HostKeyRedactionTests {
    @Test func logLinesCarryNoKeyMaterial() throws {
        let log = LogRecorder()
        let verifier = HostKeyVerifier(store: MemoryHostKeyStore(), record: log.record)
        let original = newHostKey()
        let impostor = newHostKey()
        _ = verifier.verify(original, for: vm)
        _ = verifier.verify(original, for: vm)
        _ = verifier.verify(impostor, for: vm)

        #expect(log.lines == [
            "hostkey trusted-on-first-use host=p/z/web-01:22",
            "hostkey matched host=p/z/web-01:22",
            "hostkey rejected-changed host=p/z/web-01:22",
        ])
        let forbidden = [original, impostor].flatMap { [base64Blob($0), HostKeyFingerprint($0).value] }
            + ["SHA256:", "ssh-ed25519", "AAAA"]
        for line in log.lines {
            for secret in forbidden { #expect(!line.contains(secret), "\(line)") }
        }
    }

    @Test func errorAndValueDescriptionsAreRedacted() throws {
        let verifier = HostKeyVerifier(store: MemoryHostKeyStore(), record: { _, _ in })
        let original = newHostKey()
        let impostor = newHostKey()
        _ = verifier.verify(original, for: vm)
        let error = try #require(verifier.verify(impostor, for: vm))
        guard case .changed(let change) = error else { return }

        var dumped = ""
        dump(error, to: &dumped)
        let renderings = [
            String(describing: error), String(reflecting: error), "\(error)",
            String(describing: change), String(describing: change.expected), String(reflecting: change.presented),
            "\(HostKeyVerificationError.storeUnavailable(vm))",
        ]
        let forbidden = [original, impostor].flatMap { [base64Blob($0), HostKeyFingerprint($0).value] }
        for text in renderings {
            for secret in forbidden { #expect(!text.contains(secret), "\(text)") }
        }
        #expect(String(describing: change.expected) == "HostKeyFingerprint(<redacted>)")
        _ = dumped  // `dump` usa el Mirror por defecto: solo para depuración local, nunca a logs.
    }

    @Test func userKeyProvisionerNeverPrintsPrivateMaterial() throws {
        let key = try KeyProvisioner(algorithm: .ecdsaP256)
        for text in [String(describing: key), String(reflecting: key), "\(key)"] {
            #expect(!text.contains("PRIVATE KEY"))
            #expect(text.contains("privateKey: <redacted>"))
        }
    }
}
