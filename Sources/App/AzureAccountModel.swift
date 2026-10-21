import AuthKit
import AzureClient
import Foundation
import OSLog

/// GH-91: estado de la sesión de un perfil Azure, sin AppKit (lo prueba
/// `AppTests` con un `az` falso). La única fuente de credenciales es la
/// sesión `az login` del usuario (research §0.1): si falta `az` o la sesión,
/// el estado es `requiresSignIn` con el motivo; nunca hay datos de ejemplo.
enum AzureSessionState: Equatable {
    /// Aún no se ha detectado `az` (ventana sin abrir).
    case idle
    /// `which az` + `az account list` + token en curso.
    case detecting
    /// Sin `az`, sin sesión, tenant que pide reautenticarse o cuenta distinta a la del perfil.
    case requiresSignIn(AzCliError)
    /// El usuario desconectó el perfil (Sign Out); la sesión `az` sigue intacta.
    case signedOut
    /// Cuenta identificada; listando tenants y suscripciones.
    case loading(AzureAccountIdentity)
    case ready(AzureAccountIdentity, [AzureTenantEntry])

    var requiresSignIn: Bool { if case .requiresSignIn = self { true } else { false } }

    var isSignedIn: Bool {
        switch self {
        case .loading, .ready: true
        default: false
        }
    }

    var identity: AzureAccountIdentity? {
        switch self {
        case .loading(let identity), .ready(let identity, _): identity
        default: nil
        }
    }

    var tenants: [AzureTenantEntry] { if case .ready(_, let tenants) = self { tenants } else { [] } }
}

/// Un tenant de la sesión `az` con las suscripciones que se pueden elegir.
struct AzureTenantEntry: Equatable, Sendable {
    let tenant: AzureTenant
    /// Solo las usables (`Enabled`, `Warned`, `PastDue`), por nombre.
    let subscriptions: [AzureSubscription]
    /// Mensaje accionable si no se pudieron listar sus suscripciones.
    let failure: String?

    var tenantID: String { tenant.tenantID }
    var displayName: String { tenant.displayName ?? tenant.defaultDomain ?? tenant.tenantID }

    func subscription(_ id: String) -> AzureSubscription? {
        subscriptions.first { $0.subscriptionID.caseInsensitiveCompare(id) == .orderedSame }
    }
}

/// Tenant y suscripción activos del perfil (`subscriptionID == nil`: solo tenant).
struct AzureSelection: Equatable, Sendable {
    var tenantID: String
    var subscriptionID: String?
}

/// Selección persistida en la suite `explorer` del perfil (namespaced; `purge`
/// la borra con el perfil). Solo IDs, nada sensible.
struct AzureSelectionStore {
    static let tenantKey = "azure.activeTenantID"
    static let subscriptionKey = "azure.activeSubscriptionID"
    let defaults: UserDefaults

    func load() -> AzureSelection? {
        guard let tenantID = defaults.string(forKey: Self.tenantKey) else { return nil }
        return AzureSelection(tenantID: tenantID, subscriptionID: defaults.string(forKey: Self.subscriptionKey))
    }

    func save(_ selection: AzureSelection) {
        defaults.set(selection.tenantID, forKey: Self.tenantKey)
        if let subscriptionID = selection.subscriptionID {
            defaults.set(subscriptionID, forKey: Self.subscriptionKey)
        } else {
            defaults.removeObject(forKey: Self.subscriptionKey)
        }
    }
}

@MainActor
final class AzureAccountModel {
    typealias DirectoryFactory = @Sendable (_ facade: AzureCredentialFacade, _ accounts: [AzCliAccount]) -> any AzureAccountDirectory

    private(set) var state: AzureSessionState = .idle { didSet { onChange?() } }
    private(set) var selection: AzureSelection? { didSet { onChange?() } }

    var onChange: (@MainActor () -> Void)?
    /// Cuenta fijada (`connect`) o liberada (`nil`, Sign Out): el coordinador
    /// actualiza el descriptor del perfil (tenant + `oid` + UPN enmascarado).
    var onIdentityChanged: (@MainActor (AzureAccountIdentity?) -> Void)?

    private let source: AzCliTokenSource
    private let makeDirectory: DirectoryFactory
    private let selectionStore: AzureSelectionStore
    /// `oid`/tenant guardados en el perfil (`nil` en un perfil sin conectar):
    /// fijan la cuenta esperada y el tenant del primer token.
    var boundAccount: @MainActor () -> (objectID: String?, tenantID: String?) = { (nil, nil) }
    private var facade: AzureCredentialFacade?
    /// Cada `connect`/`disconnect` invalida los resultados de los anteriores.
    private var generation = 0
    static let log = Logger(subsystem: "com.iapdesktop.mac", category: "azure.session")

    init(
        source: AzCliTokenSource,
        selectionStore: AzureSelectionStore,
        makeDirectory: @escaping DirectoryFactory
    ) {
        self.source = source
        self.selectionStore = selectionStore
        self.makeDirectory = makeDirectory
    }

    /// Token ARM del perfil para `tenantID` (para el árbol/túnel de #92+).
    var accessToken: (@Sendable (String) async throws -> String)? {
        guard let facade, state.isSignedIn else { return nil }
        return { try await facade.accessToken(tenantID: $0) }
    }

    /// Detecta `az` y su sesión, fija la cuenta del perfil y lista tenants y
    /// suscripciones. Se puede repetir (Reintentar, Refresh, volver a la app).
    func connect() async {
        generation += 1
        let current = generation
        state = .detecting
        let bound = boundAccount()
        let facade = AzureCredentialFacade(source: source, expectedObjectID: bound.objectID)
        let identity: AzureAccountIdentity
        do {
            identity = try await facade.connect(tenantID: bound.tenantID)
        } catch {
            guard current == generation else { return }
            let reason = error as? AzCliError ?? .malformedOutput
            Self.log.notice("azure session requires sign-in reason=\(String(describing: reason), privacy: .public)")
            self.facade = nil
            state = .requiresSignIn(reason)
            return
        }
        guard current == generation else { return }
        self.facade = facade
        onIdentityChanged?(identity)
        state = .loading(identity)

        let accounts = await facade.accounts
        let tenants = await Self.listTenants(
            directory: makeDirectory(facade, accounts), homeTenantID: identity.tenantID)
        guard current == generation else { return }
        selection = Self.resolveSelection(stored: selectionStore.load(), tenants: tenants, accounts: accounts)
        state = .ready(identity, tenants)
        Self.log.notice("""
            azure session ready tenants=\(tenants.count, privacy: .public) \
            subscriptions=\(tenants.reduce(0) { $0 + $1.subscriptions.count }, privacy: .public)
            """)
    }

    /// Sign Out del perfil: olvida la cuenta y los tokens en memoria. No hace
    /// `az logout` (la sesión del CLI es del usuario).
    func disconnect() async {
        generation += 1
        let facade = self.facade
        self.facade = nil
        selection = nil
        state = .signedOut
        onIdentityChanged?(nil)
        if let facade { await facade.disconnect() } else { await source.clearCache() }
    }

    /// Ventana cerrada: descarta cargas en curso y los tokens en memoria, sin
    /// tocar la cuenta fijada en el perfil (no es un Sign Out).
    func close() async {
        generation += 1
        facade = nil
        onIdentityChanged = nil
        onChange = nil
        await source.clearCache()
    }

    /// Elige tenant (y suscripción) activos. Solo valores de la sesión actual.
    @discardableResult
    func select(tenantID: String, subscriptionID: String?) -> Bool {
        guard let tenant = state.tenants.first(where: { $0.tenantID.caseInsensitiveCompare(tenantID) == .orderedSame })
        else { return false }
        var choice = AzureSelection(tenantID: tenant.tenantID, subscriptionID: nil)
        if let subscriptionID {
            guard let subscription = tenant.subscription(subscriptionID) else { return false }
            choice.subscriptionID = subscription.subscriptionID
        }
        selectionStore.save(choice)
        selection = choice
        return true
    }

    // MARK: - Lógica pura

    /// Tenants (`az account list` + `GET /tenants`) y sus suscripciones, en
    /// paralelo. Un tenant que falla (MFA, sin permisos) queda con su motivo.
    nonisolated static func listTenants(directory: any AzureAccountDirectory, homeTenantID: String) async -> [AzureTenantEntry] {
        let tenants = (try? await directory.tenants(homeTenantID: homeTenantID)) ?? [AzureTenant(tenantID: homeTenantID)]
        return await withTaskGroup(of: (Int, AzureTenantEntry).self) { group in
            for (index, tenant) in tenants.enumerated() {
                group.addTask {
                    do {
                        let subscriptions = try await directory.subscriptions(tenantID: tenant.tenantID)
                            .filter(\.isUsable)
                            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                        return (index, AzureTenantEntry(tenant: tenant, subscriptions: subscriptions, failure: nil))
                    } catch {
                        return (index, AzureTenantEntry(tenant: tenant, subscriptions: [], failure: message(for: error)))
                    }
                }
            }
            var entries: [(Int, AzureTenantEntry)] = []
            for await entry in group { entries.append(entry) }
            return entries.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Selección efectiva: la guardada si sigue existiendo; si no, la
    /// suscripción por defecto de `az`; si no, la primera disponible.
    nonisolated static func resolveSelection(
        stored: AzureSelection?, tenants: [AzureTenantEntry], accounts: [AzCliAccount]
    ) -> AzureSelection? {
        func find(_ tenantID: String) -> AzureTenantEntry? {
            tenants.first { $0.tenantID.caseInsensitiveCompare(tenantID) == .orderedSame }
        }
        if let stored, let tenant = find(stored.tenantID) {
            if let subscriptionID = stored.subscriptionID {
                if let subscription = tenant.subscription(subscriptionID) {
                    return AzureSelection(tenantID: tenant.tenantID, subscriptionID: subscription.subscriptionID)
                }
            } else {
                return AzureSelection(tenantID: tenant.tenantID, subscriptionID: nil)
            }
        }
        if let preferred = accounts.first(where: { $0.isDefault && !$0.isTenantLevel }) {
            for tenant in tenants {
                if let subscription = tenant.subscription(preferred.id) {
                    return AzureSelection(tenantID: tenant.tenantID, subscriptionID: subscription.subscriptionID)
                }
            }
        }
        if let tenant = tenants.first(where: { !$0.subscriptions.isEmpty }) {
            return AzureSelection(tenantID: tenant.tenantID, subscriptionID: tenant.subscriptions[0].subscriptionID)
        }
        return tenants.first.map { AzureSelection(tenantID: $0.tenantID, subscriptionID: nil) }
    }

    /// Motivo legible (sin tokens ni respuesta cruda) de un tenant que no cargó.
    nonisolated static func message(for error: any Error) -> String {
        switch error {
        case let error as AzCliError:
            return error.userMessage
        case AzureARMError.http(let status, _, _) where status == 401 || status == 403:
            return "Sin permiso para listar las suscripciones de este tenant (HTTP \(status))."
        case AzureARMError.http(let status, _, _), AzureARMError.throttled(let status):
            return "Azure Resource Manager respondió HTTP \(status)."
        case AzureARMError.network:
            return "No se pudo contactar con Azure Resource Manager."
        default:
            return "No se pudieron listar las suscripciones de este tenant."
        }
    }
}
