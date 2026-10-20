// GH-89 (decisión del dueño, 2026-10-20): la autenticación Azure se hace SOLO
// con la sesión `az login` del usuario. Sin app registration, sin refresh
// tokens propios y sin nada en disco ni Keychain: `AzCliTokenSource` pide a
// `az` un token ARM por tenant y lo cachea en memoria.
import Foundation
import OSLog

/// Sesión Azure de UN perfil, respaldada por la sesión `az login`. El perfil
/// fija la cuenta (`oid`) con la que se conectó: si `az` pasa a otra cuenta
/// (otro `az login`), se detecta en vez de mezclar identidades.
public actor AzureCredentialFacade {
    private let source: AzCliTokenSource
    private let expectedObjectID: String?
    private var current: AzureAccountIdentity?
    private var knownAccounts: [AzCliAccount] = []
    /// Época de sesión: un token que llega tras desconectar no se entrega.
    private var generation: UInt64 = 0
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private static let log = Logger(subsystem: "com.iapdesktop.mac", category: "auth.azure")

    /// - Parameter expectedObjectID: `oid` guardado en el perfil
    ///   (`ProfileDescriptor.azureObjectID`); `nil` en un perfil nuevo.
    public init(source: AzCliTokenSource, expectedObjectID: String? = nil) {
        self.source = source
        self.expectedObjectID = expectedObjectID
    }

    public var identity: AzureAccountIdentity? { current }
    public var isConnected: Bool { current != nil }
    /// Suscripciones/tenants que `az account list` mostró al conectar.
    public var accounts: [AzCliAccount] { knownAccounts }

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

    /// Detecta `az` y su sesión, pide un token (del `tenantID` dado o del
    /// tenant por defecto de `az`) y fija la identidad del perfil. Lanza un
    /// `AzCliError` accionable (`userMessage`) si no hay `az` o sesión.
    @discardableResult
    public func connect(tenantID: String? = nil) async throws -> AzureAccountIdentity {
        let status = await source.status()
        guard case .ready(let accounts) = status else {
            if case .unavailable(let error) = status { throw error }
            throw AzCliError.notLoggedIn
        }
        let gen = generation
        let token = try await source.accessToken(tenantID: tenantID)
        let identity = try token.identity()
        guard generation == gen else { throw AzCliError.sessionChanged }
        if let expectedObjectID, identity.objectID.caseInsensitiveCompare(expectedObjectID) != .orderedSame {
            throw AzCliError.accountMismatch
        }
        current = identity
        knownAccounts = accounts
        generation &+= 1
        Self.log.notice("azure session connected source=az tenant=\(identity.tenantID, privacy: .public)")
        emitReauthorized()
        return identity
    }

    /// Token ARM para `tenantID` (de la caché de `AzCliTokenSource` o de `az`).
    /// Comprueba que sigue siendo la misma cuenta que al conectar.
    public func accessToken(tenantID: String) async throws -> String {
        guard let connected = current else { throw AzCliError.notLoggedIn }
        let gen = generation
        let token = try await source.accessToken(tenantID: tenantID)
        guard generation == gen else { throw AzCliError.sessionChanged }
        guard try token.identity().objectID.caseInsensitiveCompare(connected.objectID) == .orderedSame else {
            throw AzCliError.accountMismatch
        }
        return token.accessToken
    }

    /// Desconecta el perfil: olvida identidad y tokens en memoria. No hace
    /// `az logout` (la sesión del CLI es del usuario y la comparten otras apps).
    public func disconnect() async {
        current = nil
        knownAccounts = []
        generation &+= 1
        await source.clearCache()
        emitReauthorized()
    }
}

extension ProfileDescriptor {
    /// Fija en el perfil Azure la cuenta de la sesión `az` (cuenta + tenant).
    /// Solo metadata no sensible: tenant, `oid` y el UPN enmascarado.
    public mutating func bindAzureAccount(_ identity: AzureAccountIdentity) {
        provider = .azure
        homeTenantID = identity.tenantID
        azureObjectID = identity.objectID
        redactedAccount = Self.redactedAccount(azureUsername: identity.username)
    }
}
