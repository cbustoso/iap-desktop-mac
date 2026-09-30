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
    /// Época de sesión: se incrementa en cada authorize/splice/revoke/restore.
    /// Permite detectar refreshes o revokes obsoletos en vuelo (re-review R2 #1/#2).
    private var generation: UInt64 = 0
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let store: KeychainStore

    public init(store: KeychainStore = KeychainStore()) {
        self.store = store
    }

    /// Época actual: captúrala antes de un refresh y pásala a `storeRefreshed`.
    public var sessionGeneration: UInt64 { generation }

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
        generation &+= 1
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
        generation &+= 1
        emitReauthorized()
    }

    /// Actualiza el access token tras un refresh y guarda el refresh token
    /// rotado si el servidor devolvió uno nuevo (review #6, re-review R2 #1).
    /// `expectedGeneration` debe ser la época capturada ANTES del refresh:
    /// si cambió (splice/revoke/authorize en vuelo), lanza `tokenExpired`
    /// sin tocar nada — nunca mezcla tokens de sesiones distintas.
    /// Si el guardado en Keychain falla tras una rotación, el token nuevo se
    /// pierde (inevitable: sin persistencia no hay sesión que guardar) y la
    /// próxima llamada refrescará o pedirá login.
    public func storeRefreshed(
        accessToken: String, expiresIn: TimeInterval, refreshToken: String?,
        expectedGeneration: UInt64
    ) throws {
        guard expectedGeneration == generation, var current = credential else {
            throw AuthError.tokenExpired
        }
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
        generation &+= 1
    }

    /// Cierra sesión (REQ-AUTH-3, re-review R2 #2/#5): intenta revocar en el
    /// servidor (best-effort) y limpia la sesión que existía AL ENTRAR.
    /// Si un authorize/splice entra durante el await de red, al volver se
    /// detecta por época y NO se toca la sesión nueva (solo se borra del
    /// Keychain la entrada vieja). El logout nunca deja al usuario atrapado;
    /// el token expira igualmente por tiempo.
    public func revoke(revokingWith revoker: RevokeClient? = nil) async {
        let outgoing = credential
        let gen = generation
        if let token = outgoing?.refreshToken, let revoker {
            _ = await revoker.revoke(token: token)
        }
        // Borrado condicional y atómico (mismo turno del actor, sin await en
        // medio): solo se borra si la entrada sigue teniendo el refresh token
        // saliente. Un re-login en la misma cuenta la habría sobrescrito y
        // entonces sobrevive (R3-C). Con otra cuenta, la entrada vieja sigue
        // intacta y se elimina con normalidad.
        if let old = outgoing,
           (try? store.load(issuer: old.issuer, email: old.email))?.refreshToken == old.refreshToken {
            _ = try? store.delete(issuer: old.issuer, email: old.email)
        }
        guard generation == gen else { return }
        credential = nil
        accessToken = nil
        accessTokenExpiry = nil
        generation &+= 1
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
