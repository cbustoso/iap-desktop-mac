// GH-72 (specs/multitenant T-MT-1/2): perfiles independientes. Un perfil =
// cuenta + client OAuth + proyectos + settings/Keychain propios, identificado
// por un `ProfileID` opaco (nunca derivado del email). Aquí solo hay metadata
// no sensible y el esquema de nombres namespaced; nada de tokens.
import Foundation
import OSLog
import Security

/// Identificador opaco y estable de un perfil.
public struct ProfileID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// Solo `[A-Za-z0-9-]`, 1…64: se usa dentro de nombres de servicio/suite.
    public init?(rawValue: String) {
        guard (1...64).contains(rawValue.count),
              rawValue.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" })
        else { return nil }
        self.rawValue = rawValue
    }

    /// Perfil al que se migra el estado de perfil único anterior (REQ-MT-5):
    /// fijo y determinista para que la migración sea idempotente.
    public static let legacyDefault = ProfileID(rawValue: "legacy-default-profile")!

    public static func generate() -> ProfileID {
        ProfileID(rawValue: UUID().uuidString.lowercased())!
    }

    public var description: String { rawValue }
}

/// Metadata no sensible de un perfil (lo que muestra el selector).
public struct ProfileDescriptor: Codable, Sendable, Equatable {
    public let id: ProfileID
    public var displayName: String
    /// `nil` mientras no haya login completado ("pendiente de iniciar sesión").
    public var issuer: OidcIssuer?
    /// Cuenta enmascarada (`a…@example.com`) o identidad workforce redactada.
    /// Nunca el email completo ni el `principal://` crudo.
    public var redactedAccount: String?
    public var lastUsedAt: Date?

    public init(id: ProfileID, displayName: String, issuer: OidcIssuer? = nil, redactedAccount: String? = nil, lastUsedAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.issuer = issuer
        self.redactedAccount = redactedAccount
        self.lastUsedAt = lastUsedAt
    }

    public var isSignedIn: Bool { issuer != nil }

    /// Cuenta para el índice: Gaia → `a…@dominio`; STS → identidad workforce redactada.
    public static func redactedAccount(issuer: OidcIssuer, account: String) -> String {
        switch issuer {
        case .gaia:
            guard let first = account.first, account.contains("@") else { return "<redacted>" }
            return "\(first)…\(LogRedaction.emailDomain(account))"
        case .sts:
            return WorkforceIdentity(principal: account).map { "\($0.pool): \($0.redactedSubject)" } ?? "<redacted>"
        }
    }
}

public enum ProfileError: Error, Sendable, Equatable {
    case notFound(ProfileID)
    case migrationVerificationFailed
    case keychainNamespaceFailure(OSStatus)
    /// GH-74: tras varios pases siguen apareciendo entradas del perfil (o no
    /// se pudo confirmar el borrado): el perfil NO se da por purgado.
    case keychainPurgeIncomplete
    /// Borrar un perfil con su ventana abierta: hay que cerrarla antes.
    case cannotRemoveActiveProfileWindow
}

/// Índice de perfiles en `UserDefaults` (clave propia, no namespaced: es el
/// único estado compartido a propósito entre perfiles). `@unchecked
/// Sendable`: `UserDefaults` es thread-safe.
public struct ProfileStore: @unchecked Sendable {
    public static let defaultsKey = "profiles.index"
    static let log = Logger(subsystem: "com.iapdesktop.mac", category: "profiles")

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Perfiles en orden de alta. Un índice ilegible se trata como vacío
    /// (sin crash, REQ-MT-6) y se registra sin datos.
    public func list() -> [ProfileDescriptor] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        guard let profiles = try? JSONDecoder().decode([ProfileDescriptor].self, from: data) else {
            Self.log.error("profiles index unreadable")
            return []
        }
        return profiles
    }

    public func descriptor(for id: ProfileID) -> ProfileDescriptor? {
        list().first { $0.id == id }
    }

    /// Alta o actualización por `id` (nunca deduplica por email).
    public func upsert(_ descriptor: ProfileDescriptor) throws {
        var profiles = list()
        if let index = profiles.firstIndex(where: { $0.id == descriptor.id }) {
            profiles[index] = descriptor
        } else {
            profiles.append(descriptor)
        }
        try save(profiles)
    }

    public func remove(_ id: ProfileID) throws {
        var profiles = list()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
        profiles.remove(at: index)
        try save(profiles)
    }

    private func save(_ profiles: [ProfileDescriptor]) throws {
        defaults.set(try JSONEncoder().encode(profiles), forKey: Self.defaultsKey)
    }

    // MARK: - Namespacing (REQ-MT-3)

    /// `com.iap-mac.<suffix>.profile.<id>` (p. ej. `auth` para `KeychainStore`).
    public static func keychainService(for id: ProfileID, suffix: String) -> String {
        "com.iap-mac.\(suffix).profile.\(id.rawValue)"
    }

    /// `com.iapdesktop.mac.settings.profile.<id>.<component>`.
    public static func userDefaultsSuite(for id: ProfileID, component: String) -> String {
        "com.iapdesktop.mac.settings.profile.\(id.rawValue).\(component)"
    }
}

/// Dónde vive el estado de UN perfil. Todos los almacenes del perfil se
/// construyen desde aquí, para que ningún componente invente su propio nombre.
///
/// - Auth, client ID y proyectos: namespaced por perfil; el perfil legado usa
///   las ubicaciones antiguas solo mientras la migración no se haya completado
///   (modo "perfil único implícito", REQ-MT-5).
/// - Settings por proyecto/zona/instancia (contraseñas RDP, panel Settings):
///   namespaced para los perfiles nuevos; el perfil legado conserva los
///   nombres de siempre (la migración no los copia, así no se pierden).
public struct ProfileEnvironment: Sendable, Equatable {
    public static let legacyAuthService = "com.iap-mac.auth"
    public static let knownProjectsKey = "knownProjectIDs"

    public let id: ProfileID
    /// `true` = perfil legado sin migrar: lee las ubicaciones antiguas.
    public let usesLegacyLocations: Bool

    public init(id: ProfileID, migrationCompleted: Bool) {
        self.id = id
        usesLegacyLocations = id == .legacyDefault && !migrationCompleted
    }

    public var authKeychainService: String {
        usesLegacyLocations ? Self.legacyAuthService : ProfileStore.keychainService(for: id, suffix: "auth")
    }

    public func keychainStore() -> KeychainStore { KeychainStore(service: authKeychainService) }

    /// Suite del override de client OAuth (`nil` = `.standard`, legado).
    public var clientIDSuite: String? {
        usesLegacyLocations ? nil : ProfileStore.userDefaultsSuite(for: id, component: "oauth")
    }

    /// Suite de `knownProjectIDs` (`nil` = `.standard`, legado).
    public var explorerSuite: String? {
        usesLegacyLocations ? nil : ProfileStore.userDefaultsSuite(for: id, component: "explorer")
    }

    public func clientIDDefaults() -> UserDefaults? { Self.defaults(clientIDSuite) }
    public func explorerDefaults() -> UserDefaults? { Self.defaults(explorerSuite) }

    static func defaults(_ suite: String?) -> UserDefaults? {
        guard let suite else { return .standard }
        return UserDefaults(suiteName: suite)
    }

    /// Servicio Keychain de settings sensibles (`component` = `p.vm-x`, …).
    public func settingsSecureService(component: String) -> String {
        id == .legacyDefault
            ? "com.iapdesktop.mac.settings.secure.\(component)"
            : "com.iapdesktop.mac.settings.secure.profile.\(id.rawValue).\(component)"
    }

    /// Suite de settings no sensibles por nivel.
    public func settingsSuite(component: String) -> String {
        id == .legacyDefault
            ? "com.iapdesktop.mac.settings.\(component)"
            : ProfileStore.userDefaultsSuite(for: id, component: component)
    }

    /// Borra el estado namespaced del perfil (al eliminarlo, REQ-MT-1): todas
    /// las entradas Keychain cuyo servicio es de este perfil y sus suites de
    /// client ID/proyectos. Nunca toca ubicaciones legadas ni otros perfiles.
    public func purge() throws {
        try purge(keychain: .system)
    }

    func purge(keychain: KeychainNamespaceAccess) throws {
        guard !usesLegacyLocations else { return }
        try Self.purgeKeychain(of: id, knownServices: [authKeychainService], keychain: keychain)
        for suite in [clientIDSuite, explorerSuite].compactMap({ $0 }) {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    /// ¿Es `service` de este perfil? (`….profile.<id>` o `….profile.<id>.<x>`).
    static func belongs(_ service: String, to id: ProfileID) -> Bool {
        let marker = ".profile.\(id.rawValue)"
        return service.hasSuffix(marker) || service.contains(marker + ".")
    }

    /// Pases máximos y lecturas limpias seguidas exigidas para dar el perfil por purgado.
    static let purgeMaxPasses = 10
    static let purgeConfirmations = 3

    /// GH-74: la enumeración global (`kSecMatchLimitAll`) del Keychain de login
    /// NO es una foto consistente: con escrituras concurrentes (otros hilos o
    /// procesos) puede omitir entradas que existen y que una consulta directa
    /// sí encuentra. Una sola lectura vacía no prueba nada, así que:
    /// 1. los servicios conocidos (auth) se borran directamente, sin enumerar;
    /// 2. el resto (settings sensibles, componentes no conocidos de antemano)
    ///    se enumera y borra en pases hasta `purgeConfirmations` lecturas
    ///    limpias seguidas; si no se confirma, se lanza error en vez de dar por
    ///    borrado lo que quizá sigue ahí.
    /// Límite: `purgeConfirmations` lecturas falsamente vacías seguidas (con
    /// 50 ms entre ellas) engañarían al purge; medido bajo carga, la omisión
    /// dura una lectura y la relectura a 50 ms ya ve la entrada.
    static func purgeKeychain(of id: ProfileID, knownServices: [String], keychain: KeychainNamespaceAccess) throws {
        for service in knownServices { try keychain.delete(service) }
        var cleanReads = 0
        for _ in 0..<purgeMaxPasses {
            let remaining = try keychain.services().filter { belongs($0, to: id) }
            if remaining.isEmpty {
                cleanReads += 1
                if cleanReads >= purgeConfirmations { return }
            } else {
                cleanReads = 0
                for service in remaining { try keychain.delete(service) }
            }
            keychain.pause()
        }
        ProfileStore.log.error("profile purge unconfirmed passes=\(purgeMaxPasses, privacy: .public)")
        throw ProfileError.keychainPurgeIncomplete
    }

    static func deleteGenericPasswords(service: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProfileError.keychainNamespaceFailure(status)
        }
    }

    static func genericPasswordServices() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let list = items as? [[String: Any]] else {
            throw ProfileError.keychainNamespaceFailure(status)
        }
        return Array(Set(list.compactMap { $0[kSecAttrService as String] as? String }))
    }
}

/// Operaciones de Keychain que usa `ProfileEnvironment.purge` (inyectables
/// para probar la enumeración incompleta sin depender del timing real).
struct KeychainNamespaceAccess: Sendable {
    var services: @Sendable () throws -> [String]
    var delete: @Sendable (_ service: String) throws -> Void
    var pause: @Sendable () -> Void

    static let system = KeychainNamespaceAccess(
        services: ProfileEnvironment.genericPasswordServices,
        delete: ProfileEnvironment.deleteGenericPasswords(service:),
        pause: { Thread.sleep(forTimeInterval: 0.05) })
}

/// Sesiones vivas por perfil (una por ventana abierta). Genérico para poder
/// probar la semántica del coordinador sin AppKit: activar un perfil abierto
/// devuelve el MISMO objeto; cerrar uno no toca a los demás.
@MainActor
public final class ProfileSessionRegistry<Session: AnyObject> {
    private var sessions: [ProfileID: Session] = [:]
    private var order: [ProfileID] = []

    public init() {}

    /// Devuelve la sesión existente o crea una con `make`.
    public func activate(_ id: ProfileID, make: () -> Session) -> (session: Session, created: Bool) {
        if let existing = sessions[id] {
            touch(id)
            return (existing, false)
        }
        let session = make()
        sessions[id] = session
        touch(id)
        return (session, true)
    }

    public func session(for id: ProfileID) -> Session? { sessions[id] }

    @discardableResult
    public func remove(_ id: ProfileID) -> Session? {
        order.removeAll { $0 == id }
        return sessions.removeValue(forKey: id)
    }

    /// Perfiles abiertos, el usado más recientemente al final.
    public var openIDs: [ProfileID] { order }

    public var mostRecent: Session? { order.last.flatMap { sessions[$0] } }

    private func touch(_ id: ProfileID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}
