import AppKit
import AuthKit
import AzureClient
import ExplorerUI
import Foundation
import OSLog

/// GH-91 (specs/azure T-AZ-6): sesión de UN perfil Azure, ligada a la sesión
/// `az login` local (cuenta + tenant). Equivale a `ProfileSession` para
/// Google, pero sin login propio: detecta `az` al abrir la ventana y, si
/// falta o no hay sesión, queda en `requiresSignIn` con el CTA. Ningún token
/// sale de memoria; el descriptor guarda solo tenant, `oid` y UPN enmascarado.
///
/// GH-98: la ventana principal es el Explorer (árbol tenant → suscripción →
/// RG → VM → Bastion) con `AzureExplorerDataSourceLive`, uno por conexión. La
/// ventana Cuenta Azure (`AzureProfileWindowController`) queda como auxiliar:
/// CTA de `az login` y elección del tenant/suscripción que muestra el árbol.
@MainActor
final class AzureProfileSession: NSObject, ProfileSessionHosting {
    /// Lo que se inyecta en tests: `az` (runner falso) y ARM (`URLProtocol`).
    struct Dependencies {
        var runner: any AzCommandRunning = ProcessAzCommandRunner()
        var armSession: URLSession = .shared
        /// `false` en tests: la ventana no se muestra en pantalla.
        var showsWindow = true

        static let live = Dependencies()
    }

    let id: ProfileID
    let environment: ProfileEnvironment
    let provider = CloudProvider.azure
    private(set) var descriptor: ProfileDescriptor
    let model: AzureAccountModel
    let explorerViewModel: ExplorerViewModel
    private let dependencies: Dependencies
    private let bastionChoices: AzureBastionChoiceStore
    /// Data source del árbol y la conexión (`model.generation`) para la que se creó.
    private(set) var explorerDataSource: AzureExplorerDataSourceLive?
    private var explorerGeneration: Int?
    private var explorerScope: AzureSelection?
    /// La ventana Cuenta Azure ya se abrió para este "falta az login" (los
    /// reintentos al volver a la app no le roban el foco cada vez).
    private var promptedForAzLogin = false
    /// Última carga del árbol (los tests la esperan).
    private(set) var explorerLoad: Task<Void, Never>?

    /// El coordinador fija (o, con `nil`, libera) la cuenta en el índice de perfiles.
    var onAccountChanged: (@MainActor (AzureProfileSession, AzureAccountIdentity?) -> Void)?
    var onWindowClosed: (@MainActor (any ProfileSessionHosting) -> Void)?
    var showsProfileName: @MainActor () -> Bool = { false }

    /// Ventana Cuenta Azure (auxiliar).
    private(set) var windowController: AzureProfileWindowController?
    /// Ventana principal del perfil.
    private(set) var explorerController: ExplorerWindowController?
    private var windowCloseGuard: WindowCloseGuard?
    private var activationObserver: (any NSObjectProtocol)?
    private(set) var connectTask: Task<Void, Never>?

    static let log = Logger(subsystem: "com.iapdesktop.mac", category: "azure.session")

    /// `nil` si no se puede abrir la suite del perfil (fallo aislado a este perfil).
    init?(id: ProfileID, descriptor: ProfileDescriptor, environment: ProfileEnvironment, dependencies: Dependencies = .live) {
        guard let explorerDefaults = environment.explorerDefaults() else { return nil }
        self.id = id
        self.descriptor = descriptor
        self.environment = environment
        self.dependencies = dependencies
        bastionChoices = AzureBastionChoiceStore(defaults: explorerDefaults)
        // Sin sesión hasta que `az` responda: el árbol muestra el CTA, nunca datos de ejemplo.
        explorerViewModel = ExplorerViewModel(
            isSignedIn: false, azureAccount: AzureExplorerAccount(id: id.rawValue, displayName: descriptor.displayName))
        let armSession = dependencies.armSession
        model = AzureAccountModel(
            source: AzCliTokenSource(runner: dependencies.runner),
            selectionStore: AzureSelectionStore(defaults: explorerDefaults),
            makeDirectory: { facade, accounts in
                AzCliAccountDirectory(
                    arm: AzureARMClient(session: armSession) { try await facade.accessToken(tenantID: $0) },
                    accounts: { accounts })
            })
        super.init()
        model.boundAccount = { [weak self] in (self?.descriptor.azureObjectID, self?.descriptor.homeTenantID) }
        model.onIdentityChanged = { [weak self] identity in
            guard let self else { return }
            self.onAccountChanged?(self, identity)
        }
    }

    var window: NSWindow? { explorerController?.window }
    var loginWindow: NSWindow? { nil }
    /// Sin pestañas hasta #94 (túnel Bastion).
    var hasOpenTabs: Bool { false }

    func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === explorerController?.window || window === windowController?.window
    }

    func update(_ descriptor: ProfileDescriptor) {
        self.descriptor = descriptor
        window?.title = windowTitle
        windowController?.window?.title = "Cuenta Azure — \(descriptor.displayName)"
        refreshAccount()
    }

    private var windowTitle: String { "IAP Desktop — \(descriptor.displayName) (Azure)" }

    // MARK: - Ventana

    /// Crea las ventanas y detecta `az` en el acto (arranque o alta del perfil).
    func openWindow() {
        let controller = AzureProfileWindowController(model: model)
        windowController = controller
        controller.window?.title = "Cuenta Azure — \(descriptor.displayName)"
        controller.onRetry = { [weak self] in self?.reconnect() }

        let explorer = ExplorerWindowController(viewModel: explorerViewModel, dataSourceLabel: "Azure")
        explorerController = explorer
        explorer.window?.title = windowTitle
        explorer.onSignInRequest = { [weak self] in self?.showLoginWindow(nil) }
        wireRefreshAction(explorer)

        model.onChange = { [weak self] in
            self?.windowController?.reload()
            self?.syncExplorer()
            self?.refreshAccount()
        }
        // Cerrar la ventana Cuenta Azure solo la oculta; cerrar el Explorer cierra el perfil.
        let closeGuard = WindowCloseGuard(shouldClose: { _ in true }, willClose: { [weak self] in
            guard let self else { return }
            self.onWindowClosed?(self)
        })
        windowCloseGuard = closeGuard
        explorer.window?.delegate = closeGuard
        if dependencies.showsWindow { explorer.showWindow(nil) }
        refreshAccount()
        // Tras `az login` en Terminal, volver a la app reintenta solo.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryIfWaitingForAzLogin() }
        }
        reconnect()
    }

    func bringToFront() {
        guard dependencies.showsWindow else { return }
        explorerController?.showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Ventana Cuenta Azure al frente (CTA de `az login` o elegir suscripción).
    func showAccountWindow() {
        guard dependencies.showsWindow else { return }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    func teardown() async {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        connectTask?.cancel()
        connectTask = nil
        windowController?.window?.close()
        endExplorerSession()
        await model.close()
    }

    // MARK: - Explorer (GH-98)

    /// Estado de la sesión `az` → árbol. Cada conexión lista (`ready`) trae su
    /// propio data source; sin `az`/sesión el árbol queda en "Sin sesión Azure"
    /// con el CTA y se abre la ventana Cuenta Azure con los comandos.
    private func syncExplorer() {
        switch model.state {
        case .ready(let identity, _):
            promptedForAzLogin = false
            if explorerGeneration != model.generation {
                startExplorerSession(identity)
            } else if explorerScope != model.selection, let source = explorerDataSource {
                // Otro tenant/suscripción activos: misma caché, otro ámbito.
                let scope = model.selection
                explorerScope = scope
                reloadExplorer { await source.setScope(scope) }
            }
        case .requiresSignIn:
            endExplorerSession()
            if !promptedForAzLogin {
                promptedForAzLogin = true
                showAccountWindow()
            }
        case .signedOut, .idle:
            endExplorerSession()
        case .detecting, .loading:
            break  // se mantiene el árbol anterior hasta que la nueva conexión esté lista
        }
    }

    private func startExplorerSession(_ identity: AzureAccountIdentity) {
        guard let token = model.accessToken else { return }
        let accounts = model.accounts
        let arm = AzureARMClient(session: dependencies.armSession, token: token)
        let source = AzureExplorerDataSourceLive(
            homeTenantID: identity.tenantID,
            directory: AzCliAccountDirectory(arm: arm, accounts: { accounts }),
            arm: arm, choices: bastionChoices, scope: model.selection)
        explorerDataSource = source
        explorerGeneration = model.generation
        explorerScope = model.selection
        let username = ProfileDescriptor.redactedAccount(azureUsername: identity.username)
        explorerViewModel.azureSessionStarted(
            account: AzureExplorerAccount(
                id: id.rawValue, displayName: username, username: username),
            dataSource: source)
        reloadExplorer()
    }

    private func endExplorerSession() {
        explorerDataSource = nil
        explorerGeneration = nil
        explorerScope = nil
        if explorerViewModel.azureState != .noSession { explorerViewModel.azureSessionEnded() }
    }

    /// Cargas en serie: un cambio de ámbito espera a la anterior. Un resultado
    /// de una sesión ya terminada lo descarta el propio ViewModel (generación).
    private func reloadExplorer(before: (@Sendable () async -> Void)? = nil) {
        let previous = explorerLoad
        explorerLoad = Task { @MainActor [explorerViewModel] in
            await previous?.value
            await before?()
            await explorerViewModel.reloadAzure()
        }
    }

    /// Refresh del toolbar = Refresh del menú: vuelve a leer la sesión `az`.
    private func wireRefreshAction(_ explorer: ExplorerWindowController) {
        let refreshID = NSToolbarItem.Identifier("iap.refresh")
        guard let item = explorer.window?.toolbar?.items.first(where: { $0.itemIdentifier == refreshID }) else { return }
        item.target = self
        item.action = #selector(refreshProfileExplorer(_:))
    }

    /// Repite la detección y la carga (Reintentar, Refresh, Sign In).
    @discardableResult
    func reconnect() -> Task<Void, Never> {
        let task = Task { @MainActor [model] in await model.connect() }
        connectTask = task
        return task
    }

    private func retryIfWaitingForAzLogin() {
        guard model.state.requiresSignIn else { return }
        Self.log.notice("azure session retry trigger=app-active")
        reconnect()
    }

    /// Cuenta en la barra inferior; con varios perfiles, precedida del nombre del perfil.
    private func refreshAccount() {
        let account = model.state.identity.map { ProfileDescriptor.redactedAccount(azureUsername: $0.username) }
            ?? (model.state.requiresSignIn || model.state == .signedOut ? "sin sesión az" : descriptor.redactedAccount)
        let text = showsProfileName() ? "\(descriptor.displayName) · \(account ?? "sin sesión az")" : account
        windowController?.showAccount(text)
        explorerController?.showAccount(email: text)
    }

    // MARK: - Acciones de menú

    /// Sin ventana Sign In propia: trae la ventana Cuenta Azure y reintenta `az`.
    @objc func showLoginWindow(_ sender: Any?) {
        showAccountWindow()
        if !model.state.isSignedIn { reconnect() }
    }

    @objc func signOut(_ sender: Any?) {
        connectTask?.cancel()
        Task { @MainActor [model] in await model.disconnect() }
    }

    @objc func refreshProfileExplorer(_ sender: Any?) { reconnect() }

    @objc func closeActiveSessionOrWindow(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }

    // Conexión, SFTP, serial, diagnóstico y event log llegan con #92–#94.
    @objc func connectSelected(_ sender: Any?) { NSSound.beep() }
    @objc func browseSelectedFiles(_ sender: Any?) { NSSound.beep() }
    @objc func showSerialPortOutput(_ sender: Any?) { NSSound.beep() }
    @objc func diagnoseSelected(_ sender: Any?) { NSSound.beep() }
    @objc func showEventLog(_ sender: Any?) { NSSound.beep() }
}
