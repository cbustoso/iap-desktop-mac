import Foundation

/// Único punto de verdad para la sesión activa (specs/auth/design.md).
///
/// El actor nunca se reemplaza: el cambio de cuenta hace `splice` (actualiza el
/// token in-place) para no romper los interceptores de `GCPClient`, y emite
/// `Reauthorized` vía `AsyncStream`.
public actor CredentialFacade {
    private var credential: OfflineCredential?
    private var accessToken: String?
    private var accessTokenExpiry: Date?
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let store: KeychainStore

    public init(store: KeychainStore = KeychainStore()) {
        self.store = store
    }

    /// Flujo de eventos `Reauthorized` (cambio de cuenta o logout).
    /// `bufferingNewest(1)`: es una señal de flanco, basta el último (review #16).
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
        for continuation in continuations.values {
            continuation.yield()
        }
    }

    /// Establece la sesión (login): memoria + Keychain.
    public func authorize(
        _ credential: OfflineCredential, accessToken: String, expiresAt: Date
    ) throws {
        try store.save(credential)
        self.credential = credential
        self.accessToken = accessToken
        self.accessTokenExpiry = expiresAt
        emitReauthorized()
    }

    /// Cambio de cuenta sin reemplazar el actor (equivale a `Splice()` C#).
    /// Si cambia el issuer Gaia↔STS, descarta la credencial offline anterior.
    /// Orden: guardar la nueva ANTES de borrar la anterior para no dejar
    /// Keychain y memoria inconsistentes si el guardado falla (review #8).
    public func splice(_ newCredential: OfflineCredential) throws {
        try store.save(newCredential)
        if let current = credential, current.issuer != newCredential.issuer {
            try store.delete(issuer: current.issuer, email: current.email)
        }
        self.credential = newCredential
        self.accessToken = nil
        self.accessTokenExpiry = nil
        emitReauthorized()
    }

    /// Actualiza el access token tras un refresh y guarda el refresh token
    /// rotado si el servidor devolvió uno nuevo (review #6).
    /// Lanza `tokenExpired` si ya no hay sesión (p. ej. un refresh que
    /// termina después de `revoke()` o `splice()`): nunca resucita sesiones.
    public func storeRefreshed(accessToken: String, expiresIn: TimeInterval, refreshToken: String?) throws {
        guard var current = credential else { throw AuthError.tokenExpired }
        if let rotated = refreshToken {
            current.refreshToken = rotated
            current.issuedAt = Date()
        }
        try store.save(current)
        self.credential = current
        self.accessToken = accessToken
        self.accessTokenExpiry = Date().addingTimeInterval(expiresIn)
    }

    /// Restores a Keychain credential into memory. The first token request must
    /// refresh because access tokens are deliberately not persisted.
    public func restoreOffline(_ credential: OfflineCredential) {
        self.credential = credential
        accessToken = nil
        accessTokenExpiry = nil
    }

    /// Cierra sesión (REQ-AUTH-3): intenta revocar en el servidor (best-effort)
    /// y SIEMPRE limpia memoria + Keychain y emite `Reauthorized`, aunque el
    /// borrado o la red fallen (review #7). El logout nunca deja al usuario
    /// atrapado; el token expira igualmente por tiempo.
    public func revoke(revokingWith revoker: RevokeClient? = nil) async {
        if let token = credential?.refreshToken, let revoker {
            _ = await revoker.revoke(token: token)
        }
        if let current = credential {
            try? store.delete(issuer: current.issuer, email: current.email)
        }
        credential = nil
        accessToken = nil
        accessTokenExpiry = nil
        emitReauthorized()
    }

    /// Token vigente o `tokenExpired` (el refresh con `refresh_token` llega en T-AUTH-3).
    public func validAccessToken() throws -> String {
        guard let token = accessToken, let expiry = accessTokenExpiry, expiry > Date() else {
            throw AuthError.tokenExpired
        }
        return token
    }

    public var currentEmail: String? { credential?.email }
    public var currentIssuer: OidcIssuer? { credential?.issuer }
    public var currentOffline: OfflineCredential? { credential }
    public var isWorkforceSession: Bool { credential?.issuer == .sts }
}
