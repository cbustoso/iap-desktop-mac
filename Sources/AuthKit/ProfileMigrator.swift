// GH-72 (T-MT-7, REQ-MT-5): migración del estado de perfil único a
// `ProfileID.legacyDefault`. Copia (nunca mueve), verifica leyendo de vuelta y
// solo entonces marca la migración; si algo falla, no marca nada ni borra lo
// legado y la app sigue en modo "perfil único implícito".
import Foundation
import OSLog

/// Lo que el migrador necesita de un Keychain de credenciales (inyectable).
public protocol CredentialVault: Sendable {
    func accounts() throws -> [(issuer: OidcIssuer, email: String)]
    func load(issuer: OidcIssuer, email: String) throws -> OfflineCredential?
    @discardableResult func save(_ credential: OfflineCredential) throws -> Bool
}

extension KeychainStore: CredentialVault {}

/// `@unchecked Sendable`: `UserDefaults` es thread-safe.
public struct ProfileMigrator: @unchecked Sendable {
    public static let completedKey = "multitenant.migration.completed"

    public enum Outcome: Sendable, Equatable {
        case alreadyMigrated
        /// No había nada que migrar: perfil legado "pendiente de login".
        case migratedEmpty
        case migrated(accounts: Int, projects: Int, clientIDOverride: Bool)
        /// Nada marcado ni borrado; la app sigue con las ubicaciones legadas.
        case failed(ProfileError)
    }

    static let log = Logger(subsystem: "com.iapdesktop.mac", category: "profiles")

    private let defaults: UserDefaults
    private let store: ProfileStore
    private let legacyVault: any CredentialVault
    private let targetVault: any CredentialVault
    private let targetDefaults: @Sendable (String) -> UserDefaults?

    public init(
        defaults: UserDefaults = .standard,
        store: ProfileStore = ProfileStore(),
        legacyVault: any CredentialVault = KeychainStore(service: ProfileEnvironment.legacyAuthService),
        targetVault: any CredentialVault = ProfileEnvironment(id: .legacyDefault, migrationCompleted: true).keychainStore(),
        targetDefaults: @escaping @Sendable (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) {
        self.defaults = defaults
        self.store = store
        self.legacyVault = legacyVault
        self.targetVault = targetVault
        self.targetDefaults = targetDefaults
    }

    public var isCompleted: Bool { defaults.bool(forKey: Self.completedKey) }

    @discardableResult
    public func migrateLegacySingleProfileIfNeeded(now: Date = Date()) -> Outcome {
        guard !isCompleted else { return .alreadyMigrated }
        let target = ProfileEnvironment(id: .legacyDefault, migrationCompleted: true)
        do {
            // 1. Estado legado (solo lectura).
            let credentials = try legacyVault.accounts().compactMap { try legacyVault.load(issuer: $0.issuer, email: $0.email) }
            let projects = defaults.stringArray(forKey: ProfileEnvironment.knownProjectsKey) ?? []
            let clientID = defaults.string(forKey: ClientIDStore.defaultsKey)

            // 2. Copia a las ubicaciones namespaced del perfil legado.
            for credential in credentials { try targetVault.save(credential) }
            guard let explorer = target.explorerSuite.flatMap(targetDefaults),
                  let oauth = target.clientIDSuite.flatMap(targetDefaults)
            else { throw ProfileError.migrationVerificationFailed }
            if !projects.isEmpty { explorer.set(projects, forKey: ProfileEnvironment.knownProjectsKey) }
            if let clientID { oauth.set(clientID, forKey: ClientIDStore.defaultsKey) }

            // 3. Verificación leyendo de vuelta: sin ella no se marca nada.
            for credential in credentials {
                guard try targetVault.load(issuer: credential.issuer, email: credential.email) == credential else {
                    throw ProfileError.migrationVerificationFailed
                }
            }
            guard (explorer.stringArray(forKey: ProfileEnvironment.knownProjectsKey) ?? []) == projects,
                  oauth.string(forKey: ClientIDStore.defaultsKey) == clientID
            else { throw ProfileError.migrationVerificationFailed }

            // 4. Índice + marca (lo último: si falla, se reintenta al arrancar).
            let account = credentials.first
            try store.upsert(ProfileDescriptor(
                id: .legacyDefault,
                displayName: store.descriptor(for: .legacyDefault)?.displayName ?? "Perfil principal",
                provider: .google,  // el estado de perfil único siempre fue Google
                issuer: account?.issuer,
                redactedAccount: account.map { ProfileDescriptor.redactedAccount(issuer: $0.issuer, account: $0.email) },
                lastUsedAt: account == nil ? nil : now))
            defaults.set(true, forKey: Self.completedKey)
            let empty = credentials.isEmpty && projects.isEmpty && clientID == nil
            Self.log.notice("""
                migration completed profile=\(ProfileID.legacyDefault.rawValue, privacy: .public) \
                accounts=\(credentials.count, privacy: .public) projects=\(projects.count, privacy: .public)
                """)
            return empty ? .migratedEmpty
                : .migrated(accounts: credentials.count, projects: projects.count, clientIDOverride: clientID != nil)
        } catch {
            let reason = (error as? ProfileError) ?? .migrationVerificationFailed
            // Sin datos sensibles: solo el tipo de fallo.
            Self.log.error("migration failed profile=\(ProfileID.legacyDefault.rawValue, privacy: .public) error=\(String(describing: reason), privacy: .public)")
            return .failed(reason)
        }
    }
}
