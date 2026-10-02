// T-SSH-7 (CBU-43): verificación de host key TOFU persistente.
// Primera conexión: se guarda la huella (Keychain, por host+puerto) y se
// acepta. Después: solo se acepta la misma huella; un cambio rechaza la
// conexión con `HostKeyVerificationError.changed` ANTES de autenticar (no se
// ofrece la llave del usuario a un servidor desconocido). Aceptar la nueva
// solo es posible con confirmación explícita (`trust(_:)`) y reconexión.
// Los logs nunca llevan material criptográfico: ni llaves ni huellas.
import CryptoKit
import Foundation
import NIOSSH
import OSLog
import Security

/// Destino lógico de la host key. Con IAP el puerto local es efímero, así que
/// `host` es la instancia (`project/zone/instance`) y `port` el remoto.
public struct HostKeyIdentity: Sendable, Hashable, CustomStringConvertible {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public init(_ target: SshTarget) {
        self.init(host: target.instanceID, port: target.port)
    }

    /// Cuenta en el Keychain y en logs (no es secreto).
    public var description: String { "\(host):\(port)" }
}

/// Huella SHA-256 del blob de la llave pública, formato OpenSSH
/// (`SHA256:` + base64 sin relleno). La muestra la UI; los logs, no.
public struct HostKeyFingerprint: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    public init(_ key: NIOSSHPublicKey) {
        let fields = String(openSSHPublicKey: key).split(separator: " ")
        let blob = fields.count >= 2 ? Data(base64Encoded: String(fields[1])) ?? Data() : Data()
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        value = "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    public var description: String { "HostKeyFingerprint(<redacted>)" }
    public var debugDescription: String { description }
}

/// Error tipado: la conexión se rechaza sin autenticar.
public enum HostKeyVerificationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// La host key no coincide con la aceptada antes (¿reinstalación o MITM?).
    case changed(HostKeyChange)
    /// No se pudo leer o guardar en el Keychain: se rechaza (fail closed).
    case storeUnavailable(HostKeyIdentity)

    /// Sin huellas ni llaves (apto para logs).
    public var description: String {
        switch self {
        case .changed(let change): return "HostKeyVerificationError.changed(\(change.identity))"
        case .storeUnavailable(let identity): return "HostKeyVerificationError.storeUnavailable(\(identity))"
        }
    }
}

/// Cambio detectado. Las huellas son para que el usuario las compare en la UI.
public struct HostKeyChange: Sendable, Equatable, CustomStringConvertible {
    public let identity: HostKeyIdentity
    public let expected: HostKeyFingerprint
    public let presented: HostKeyFingerprint

    public var description: String { "HostKeyChange(\(identity), fingerprints: <redacted>)" }

    /// Texto para el usuario (estilo OpenSSH), con ambas huellas.
    public var userMessage: String {
        "La identidad (host key) de \(identity.host) cambió desde la última conexión. "
            + "Conexión bloqueada por seguridad.\nEsperada: \(expected.value)\nRecibida: \(presented.value)"
    }
}

/// Almacén de huellas aceptadas.
public protocol HostKeyStore: Sendable {
    func fingerprint(for identity: HostKeyIdentity) throws -> HostKeyFingerprint?
    func save(_ fingerprint: HostKeyFingerprint, for identity: HostKeyIdentity) throws
    func remove(_ identity: HostKeyIdentity) throws
}

/// Huellas en el Keychain (genérico, `service` + cuenta `host:port`), solo
/// accesibles con el Mac desbloqueado y sin sincronizar con iCloud.
public struct KeychainHostKeyStore: HostKeyStore {
    public static let defaultService = "com.iapdesktop.mac.ssh.known-hosts"
    public let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public enum Failure: Error, Equatable { case status(OSStatus) }

    public func fingerprint(for identity: HostKeyIdentity) throws -> HostKeyFingerprint? {
        var query = baseQuery(identity)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw Failure.status(status)
        }
        return HostKeyFingerprint(value: value)
    }

    public func save(_ fingerprint: HostKeyFingerprint, for identity: HostKeyIdentity) throws {
        let data = Data(fingerprint.value.utf8)
        var insert = baseQuery(identity)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(baseQuery(identity) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw Failure.status(update) }
        } else if status != errSecSuccess {
            throw Failure.status(status)
        }
    }

    public func remove(_ identity: HostKeyIdentity) throws {
        let status = SecItemDelete(baseQuery(identity) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }

    /// Borra todas las huellas de este `service` (tests / "olvidar hosts").
    public func removeAll() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }

    private func baseQuery(_ identity: HostKeyIdentity) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identity.description,
        ]
    }
}

/// TOFU: acepta y guarda la primera host key; rechaza cambios.
public struct HostKeyVerifier: Sendable {
    public enum Outcome: Sendable, Equatable {
        case trustedOnFirstUse
        case matched
        case rejectedChanged
        case rejectedStoreUnavailable
    }

    static let log = Logger(subsystem: "com.iapdesktop.mac", category: "ssh")

    private let store: any HostKeyStore
    private let record: @Sendable (HostKeyIdentity, Outcome) -> Void

    /// - Parameter record: observador de resultados (tests); por defecto, OSLog.
    public init(
        store: any HostKeyStore = KeychainHostKeyStore(),
        record: @escaping @Sendable (HostKeyIdentity, Outcome) -> Void = HostKeyVerifier.logToOSLog
    ) {
        self.store = store
        self.record = record
    }

    /// Registro por defecto: solo `logLine` (destino + resultado).
    public static func logToOSLog(_ identity: HostKeyIdentity, _ outcome: Outcome) {
        let line = logLine(identity: identity, outcome: outcome)
        switch outcome {
        case .trustedOnFirstUse, .matched: log.notice("\(line, privacy: .public)")
        case .rejectedChanged, .rejectedStoreUnavailable: log.error("\(line, privacy: .public)")
        }
    }

    public func policy(for target: SshTarget) -> SSHHostKeyPolicy {
        policy(for: HostKeyIdentity(target))
    }

    public func policy(for identity: HostKeyIdentity) -> SSHHostKeyPolicy {
        SSHHostKeyPolicy { key in verify(key, for: identity) }
    }

    /// `nil` = aceptada; si no, el error con el que se rechaza.
    public func verify(_ key: NIOSSHPublicKey, for identity: HostKeyIdentity) -> HostKeyVerificationError? {
        let presented = HostKeyFingerprint(key)
        let known: HostKeyFingerprint?
        do {
            known = try store.fingerprint(for: identity)
        } catch {
            record(identity, .rejectedStoreUnavailable)
            return .storeUnavailable(identity)
        }
        guard let known else {
            do {
                try store.save(presented, for: identity)
            } catch {
                // Sin poder recordarla, TOFU no protege la siguiente vez: se rechaza.
                record(identity, .rejectedStoreUnavailable)
                return .storeUnavailable(identity)
            }
            record(identity, .trustedOnFirstUse)
            return nil
        }
        guard known == presented else {
            record(identity, .rejectedChanged)
            return .changed(HostKeyChange(identity: identity, expected: known, presented: presented))
        }
        record(identity, .matched)
        return nil
    }

    /// Confirmación explícita del usuario ante un cambio: acepta la huella
    /// nueva; la siguiente conexión la verificará como conocida.
    public func trust(_ change: HostKeyChange) throws {
        try store.save(change.presented, for: change.identity)
    }

    /// Olvida la huella (p. ej. VM recreada a propósito).
    public func forget(_ identity: HostKeyIdentity) throws {
        try store.remove(identity)
    }

    /// Línea de log: destino y resultado, nunca llaves ni huellas.
    public static func logLine(identity: HostKeyIdentity, outcome: Outcome) -> String {
        let result: String
        switch outcome {
        case .trustedOnFirstUse: result = "trusted-on-first-use"
        case .matched: result = "matched"
        case .rejectedChanged: result = "rejected-changed"
        case .rejectedStoreUnavailable: result = "rejected-store-unavailable"
        }
        return "hostkey \(result) host=\(identity)"
    }
}
