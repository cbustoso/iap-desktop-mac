import AppKit
import AuthKit
import AzureClient
import Foundation
import OSLog

/// GH-91 (specs/azure T-AZ-6): sesión de UN perfil Azure, ligada a la sesión
/// `az login` local (cuenta + tenant). Equivale a `ProfileSession` para
/// Google, pero sin login propio: detecta `az` al abrir la ventana y, si
/// falta o no hay sesión, queda en `requiresSignIn` con el CTA. Ningún token
/// sale de memoria; el descriptor guarda solo tenant, `oid` y UPN enmascarado.
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
    private let dependencies: Dependencies

    /// El coordinador fija (o, con `nil`, libera) la cuenta en el índice de perfiles.
    var onAccountChanged: (@MainActor (AzureProfileSession, AzureAccountIdentity?) -> Void)?
    var onWindowClosed: (@MainActor (any ProfileSessionHosting) -> Void)?
    var showsProfileName: @MainActor () -> Bool = { false }

    private(set) var windowController: AzureProfileWindowController?
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

    var window: NSWindow? { windowController?.window }
    var loginWindow: NSWindow? { nil }
    /// Sin pestañas hasta #94 (túnel Bastion).
    var hasOpenTabs: Bool { false }

    func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === windowController?.window
    }

    func update(_ descriptor: ProfileDescriptor) {
        self.descriptor = descriptor
        window?.title = windowTitle
        refreshAccount()
    }

    private var windowTitle: String { "IAP Desktop — \(descriptor.displayName) (Azure)" }

    // MARK: - Ventana

    /// Crea la ventana y detecta `az` en el acto (arranque o alta del perfil).
    func openWindow() {
        let controller = AzureProfileWindowController(model: model)
        windowController = controller
        controller.window?.title = windowTitle
        controller.onRetry = { [weak self] in self?.reconnect() }
        model.onChange = { [weak self] in
            self?.windowController?.reload()
            self?.refreshAccount()
        }
        let closeGuard = WindowCloseGuard(shouldClose: { _ in true }, willClose: { [weak self] in
            guard let self else { return }
            self.onWindowClosed?(self)
        })
        windowCloseGuard = closeGuard
        controller.window?.delegate = closeGuard
        if dependencies.showsWindow { controller.showWindow(nil) }
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
        windowController?.showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func teardown() async {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        connectTask?.cancel()
        connectTask = nil
        await model.close()
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
    }

    // MARK: - Acciones de menú

    /// Sin ventana Sign In propia: trae la ventana al frente y reintenta `az`.
    @objc func showLoginWindow(_ sender: Any?) {
        bringToFront()
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
