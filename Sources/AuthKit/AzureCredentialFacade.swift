// GH-89 (specs/azure/azure-bastion-research.md §1.4, §1.5, §9.1): sesión Entra
// de UN perfil. Solo el refresh token vive en Keychain (servicio
// `com.iap-mac.azure.profile.<id>`, cuenta `<tid>:<oid>`); los access tokens,
// uno por tenant, solo en memoria.
import Foundation
import OSLog
import Security

/// Credencial offline Entra persistida. Tokens redactados en cualquier texto.
public struct AzureOfflineCredential: Sendable, Codable, Equatable {
    public var identity: EntraIdentity
    public var refreshToken: String
    public var scopes: [String]
    public var issuedAt: Date

    public init(identity: EntraIdentity, refreshToken: String, scopes: [String] = EntraClientConfig.signInScopes, issuedAt: Date = Date()) {
        self.identity = identity
        self.refreshToken = refreshToken
        self.scopes = scopes
        self.issuedAt = issuedAt
    }
}

extension AzureOfflineCredential: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "AzureOfflineCredential(\(identity), issuedAt: \(issuedAt), tokens: <redacted>)" }
    public var debugDescription: String { description }
}

/// Keychain de credenciales Entra de un perfil (un servicio por perfil).
public struct AzureKeychainStore: Sendable {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public init(environment: ProfileEnvironment) {
        self.init(service: environment.azureKeychainService)
    }

    private func query(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    public func save(_ credential: AzureOfflineCredential) throws {
        let payload = try JSONEncoder().encode(credential)
        var query = query(account: credential.identity.keychainAccount)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = payload
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw AuthError.keychain(status: added) }
            return
        }
        guard status == errSecSuccess else { throw AuthError.keychain(status: status) }
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: payload] as CFDictionary)
        guard updated == errSecSuccess else { throw AuthError.keychain(status: updated) }
    }

    public func load(account: String) throws -> AzureOfflineCredential? {
        var query = query(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw AuthError.keychain(status: status) }
        return try JSONDecoder().decode(AzureOfflineCredential.self, from: data)
    }

    /// Cuentas (`<tid>:<oid>`) guardadas, sin leer los secretos.
    public func accounts() throws -> [String] {
        var query = query()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw AuthError.keychain(status: status) }
        let list = (item as? [[String: Any]]) ?? (item as? [String: Any]).map { [$0] } ?? []
        return list.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    @discardableResult
    public func delete(account: String) throws -> Bool {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw AuthError.keychain(status: status) }
        return true
    }

    /// Borra todas las cuentas del servicio (el perfil entero).
    public func deleteAll() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AuthError.keychain(status: status) }
    }
}

/// Sesión Entra de un perfil: refresh token persistido + caché de access
/// tokens por tenant. El refresh se serializa por tenant (N peticiones
/// concurrentes al mismo tenant = 1 llamada a `/token`) y guarda el refresh
/// token rotado. Emite `Reauthorized` como `CredentialFacade`.
public actor AzureCredentialFacade {
    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }

    private let store: AzureKeychainStore
    private let authorizer: any EntraTokenRefreshing
    private let now: @Sendable () -> Date
    private let skew: TimeInterval
    private var credential: AzureOfflineCredential?
    private var tokens: [String: CachedToken] = [:]
    private var inflight: [String: (id: UUID, task: Task<EntraTokenResponse, any Error>)] = [:]
    /// Época de sesión: un refresh que vuelve tras login/logout no se aplica.
    private var generation: UInt64 = 0
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private static let log = Logger(subsystem: "com.iapdesktop.mac", category: "auth.azure")

    public init(
        store: AzureKeychainStore, authorizer: any EntraTokenRefreshing,
        skew: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.authorizer = authorizer
        self.skew = skew
        self.now = now
    }

    public var identity: EntraIdentity? { credential?.identity }
    public var isSignedIn: Bool { credential != nil }

    public func reauthorized() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeContinuation(id: id) }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emitReauthorized() {
        for continuation in continuations.values { continuation.yield() }
    }

    /// Login completado (PKCE o device code): exige refresh token e identidad,
    /// guarda en Keychain y cachea el access token del tenant de origen.
    /// Otra cuenta en el mismo perfil reemplaza a la anterior (un perfil = una cuenta).
    @discardableResult
    public func authorize(_ response: EntraTokenResponse) throws -> EntraIdentity {
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else { throw EntraAuthError.missingRefreshToken }
        let identity = try response.identity()
        let fresh = AzureOfflineCredential(identity: identity, refreshToken: refreshToken, issuedAt: now())
        try store.save(fresh)
        if let previous = credential?.identity, previous != identity {
            _ = try? store.delete(account: previous.keychainAccount)
        }
        resetSession(to: fresh)
        tokens[identity.homeTenantID] = cached(response)
        Self.log.notice("azure session authorized tenant=\(identity.homeTenantID, privacy: .public)")
        emitReauthorized()
        return identity
    }

    /// Restaura la sesión guardada (sin red). `false` = perfil sin login.
    @discardableResult
    public func restore() throws -> Bool {
        guard let account = try store.accounts().first, let saved = try store.load(account: account) else { return false }
        resetSession(to: saved)
        return true
    }

    /// Access token ARM para `tenantID` (de la caché o refrescando).
    public func accessToken(tenantID: String) async throws -> String {
        guard EntraClientConfig.isValidTenant(tenantID) else { throw EntraAuthError.invalidTenant }
        if let token = tokens[tenantID], token.expiresAt > now() { return token.value }
        guard let current = credential else { throw EntraAuthError.requiresSignIn }

        let gen = generation
        let entry: (id: UUID, task: Task<EntraTokenResponse, any Error>)
        if let running = inflight[tenantID] {
            entry = running
        } else {
            let authorizer = self.authorizer
            let refreshToken = current.refreshToken
            entry = (UUID(), Task { try await authorizer.refresh(refreshToken, tenantID: tenantID) })
            inflight[tenantID] = entry
        }
        let result = await entry.task.result
        if inflight[tenantID]?.id == entry.id { inflight[tenantID] = nil }
        guard generation == gen else { throw EntraAuthError.sessionChanged }

        let response = try result.get()
        // Varios llamadores comparten el mismo resultado: aplicar una sola vez.
        if tokens[tenantID]?.value != response.accessToken {
            tokens[tenantID] = cached(response)
            if let rotated = response.refreshToken, !rotated.isEmpty, rotated != credential?.refreshToken, var updated = credential {
                updated.refreshToken = rotated
                updated.issuedAt = now()
                credential = updated
                do {
                    try store.save(updated)
                } catch {
                    // Se sigue con el token en memoria; al reiniciar se usará el
                    // anterior (Entra no invalida al rotar) o se pedirá login.
                    Self.log.error("azure refresh token rotation not persisted error=\(String(describing: error), privacy: .public)")
                }
            }
        }
        return response.accessToken
    }

    /// Cierra la sesión del perfil: Keychain + memoria. (Entra no tiene un
    /// endpoint de revocación para public clients: el token caduca por tiempo.)
    public func signOut() throws {
        if let account = credential?.identity.keychainAccount { try store.delete(account: account) }
        resetSession(to: nil)
        emitReauthorized()
    }

    /// Borra todo el estado Azure del perfil (al eliminarlo). `ProfileEnvironment.purge`
    /// también borra el servicio; esto además limpia la memoria.
    public func purge() throws {
        try store.deleteAll()
        resetSession(to: nil)
        emitReauthorized()
    }

    private func resetSession(to credential: AzureOfflineCredential?) {
        self.credential = credential
        tokens.removeAll()
        for entry in inflight.values { entry.task.cancel() }
        inflight.removeAll()
        generation &+= 1
    }

    private func cached(_ response: EntraTokenResponse) -> CachedToken {
        CachedToken(value: response.accessToken, expiresAt: now().addingTimeInterval(max(0, TimeInterval(response.expiresIn) - skew)))
    }
}
