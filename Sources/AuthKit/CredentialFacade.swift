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
    public func reauthorized() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
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
    public func splice(_ newCredential: OfflineCredential) throws {
        if let current = credential, current.issuer != newCredential.issuer {
            try store.delete(issuer: current.issuer, email: current.email)
        }
        try store.save(newCredential)
        self.credential = newCredential
        self.accessToken = nil
        self.accessTokenExpiry = nil
        emitReauthorized()
    }

    /// Cierra sesión: limpia memoria + Keychain y notifica.
    public func revoke() throws {
        if let current = credential {
            try store.delete(issuer: current.issuer, email: current.email)
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
    public var isWorkforceSession: Bool { credential?.issuer == .sts }
}
