import AppKit
import AuthKit
import ExplorerUI
import GCPClient
import OSLog
import RDPBridge
import SFTPKit
import SSHKit
import TerminalUI
import TunnelKit

/// GH-72 (T-MT-3): todo lo que antes era "la app" (una fachada, un GCPClient,
/// una ventana, sus pestañas y sesiones) con alcance de UN perfil. Cada perfil
/// abierto tiene su propia instancia: nada de estado compartido entre ellas
/// (ni `static` mutable). La lógica interna de SSH/RDP/SFTP/GCP no cambia:
/// solo se instancia una vez por perfil.
@MainActor
final class ProfileSession: NSObject {
    let id: ProfileID
    let environment: ProfileEnvironment
    private(set) var descriptor: ProfileDescriptor
    let credentialFacade: CredentialFacade
    private let clientIDDefaults: UserDefaults
    private let explorerDefaults: UserDefaults

    /// El coordinador actualiza el índice (issuer/cuenta redactada/último uso).
    var onAccountChanged: (@MainActor (ProfileSession, OfflineCredential?) -> Void)?
    /// La ventana se cerró (tras limpiar sus pestañas): el coordinador lo libera.
    var onWindowClosed: (@MainActor (ProfileSession) -> Void)?
    /// ¿Hay más de un perfil? Entonces la status bar antepone el nombre del perfil.
    var showsProfileName: @MainActor () -> Bool = { false }

    private(set) var windowController: ExplorerWindowController?
    private var loginWindowController: LoginWindowController?
    private var settingsPanelController: SettingsPanelWindowController?
    let viewModel = ExplorerViewModel(projects: MockWorkspace.sample())

    private lazy var workspace = ProjectWorkspace(client: GCPClient(tokenProvider: accessToken))
    private lazy var vmClient = GCPClient(tokenProvider: accessToken)
    private var serialOutputPanels: [String: SerialOutputWindowController] = [:]
    private lazy var diagnosticsPanels = DiagnosticsPanels(client: vmClient, accessToken: accessToken)
    private var eventLogPanels: [String: EventLogWindowController] = [:]
    private var inventoryPanels: [String: InventoryWindowController] = [:]

    nonisolated static let log = Logger(subsystem: "com.iapdesktop.mac", category: "login")

    /// `nil` si no se pueden abrir las suites del perfil (fallo aislado a este perfil).
    init?(id: ProfileID, descriptor: ProfileDescriptor, environment: ProfileEnvironment) {
        guard let clientIDDefaults = environment.clientIDDefaults(),
              let explorerDefaults = environment.explorerDefaults()
        else { return nil }
        self.id = id
        self.descriptor = descriptor
        self.environment = environment
        self.clientIDDefaults = clientIDDefaults
        self.explorerDefaults = explorerDefaults
        credentialFacade = CredentialFacade(store: environment.keychainStore())
        super.init()
    }

    func update(_ descriptor: ProfileDescriptor) {
        self.descriptor = descriptor
        windowController?.window?.title = windowTitle
        Task { await refreshAccount() }
    }

    var window: NSWindow? { windowController?.window }

    /// Ventanas de este perfil (Explorer, Sign In, Settings, paneles).
    func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        let mine: [NSWindow?] = [windowController?.window, loginWindowController?.window, settingsPanelController?.window]
            + serialOutputPanels.values.map(\.window) + eventLogPanels.values.map(\.window)
            + inventoryPanels.values.map(\.window)
        return mine.contains { $0 === window }
    }

    var hasOpenTabs: Bool { !(windowController?.sessionTabs.sessionIdentifiers.isEmpty ?? true) }

    private var windowTitle: String { "IAP Desktop — \(descriptor.displayName)" }

    /// Token OAuth del perfil (refresh automático vía su fachada y su client).
    /// Compartido por Compute, OS Login y el túnel IAP DE ESTE perfil; nunca se registra.
    private lazy var accessToken: @Sendable () async throws -> String = {
        let facade = self.credentialFacade
        // Solo el nombre de la suite (Sendable); `nil` = `.standard` (legado sin migrar).
        let suite = environment.clientIDSuite
        return {
            if let token = try? await facade.validAccessToken() { return token }
            do {
                guard let defaults = suite.map({ UserDefaults(suiteName: $0) }) ?? .standard else {
                    throw AuthError.clientNotConfigured
                }
                let store = ClientIDStore(defaults: defaults)
                guard let clientID = try? store.resolve() else { throw AuthError.clientNotConfigured }
                let token = try await TokenRefresher().refreshedAccessToken(
                    facade: facade,
                    client: TokenClient(clientID: clientID, clientSecret: store.clientSecret()))
                ProfileSession.log.notice("token refresh succeeded \(BuildInfo.current, privacy: .public)")
                return token
            } catch {
                ProfileSession.log.error("""
                    token refresh failed \(AppDelegate.diagnose(error).logCause, privacy: .public) \
                    \(BuildInfo.current, privacy: .public)
                    """)
                throw error
            }
        }
    }()

    // MARK: SSH vía IAP (CBU-44)

    /// Host keys aceptadas en esta ejecución, por perfil (TOFU provisional).
    private let knownHosts = InMemoryKnownHosts()
    private var terminalTabs: TerminalTabManager?
    /// Conexión SSH de cada pestaña DE ESTE perfil.
    private(set) var sshSessions: [String: SshSession] = [:]
    private var connecting: Set<String> = []

    private lazy var sshConnector: SshConnector = {
        let facade = credentialFacade
        let knownHosts = self.knownHosts
        let services = GCPSshCredentialServices(
            client: GCPClient(tokenProvider: accessToken),
            email: { await facade.currentEmail })
        return SshConnector(
            accessToken: accessToken,
            resolver: CredentialResolver(
                osLoginStatusProvider: services,
                osLoginAuthorizer: services,
                metadataPublisher: services),
            hostKeys: { knownHosts.policy(for: $0) },
            emailHint: { await facade.currentEmail ?? "" })
    }()

    // MARK: RDP vía fallback .rdp + Windows App (CBU-52)

    private lazy var rdpFlow: RdpConnectFlow = {
        let facade = credentialFacade
        return RdpConnectFlow(
            client: vmClient,
            tunnels: IapRdpTunnels(accessToken: accessToken),
            environment: environment,
            email: { await facade.currentEmail },
            window: { [weak self] in self?.windowController?.window },
            note: { [weak self] in self?.windowController?.statusNote = $0 })
    }()
    private var windowsConnect: WindowsConnectInterposer?
    private var sftpBrowsers: SftpBrowsers?
    private var closeCoordinator: SessionCloseCoordinator?
    private var windowCloseGuard: WindowCloseGuard?

    // MARK: - Ventana

    /// Crea la ventana del perfil y su wiring (lo que antes hacía
    /// `applicationDidFinishLaunching`), y restaura su sesión.
    func openWindow() {
        let windowController = ExplorerWindowController(viewModel: viewModel, dataSourceLabel: "MOCK")
        self.windowController = windowController
        windowController.window?.title = windowTitle
        windowController.onAddProject = { [weak self] in self?.addProjectDialog(nil) }
        let settingsDataSource = ApplicationSettingsDataSource(environment: environment) { [weak self] in
            self?.viewModel.projects ?? []
        }
        let settingsPanel = SettingsPanelWindowController(dataSource: settingsDataSource)
        settingsPanelController = settingsPanel
        windowController.onOpenSettings = { [weak settingsPanel] scope in
            settingsPanel?.show(preferredScope: scope)
        }
        wireSshConnect()
        wireVmControl()
        wireRdpConnect()
        wireInventory()
        windowController.showWindow(nil)
        wireRefreshAction()
        restoreSessionAndLoad()
    }

    func bringToFront() {
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Tras cerrar la ventana (las pestañas ya se cerraron en `windowShouldClose`).
    func teardown() async {
        for window in [loginWindowController?.window, settingsPanelController?.window]
            + serialOutputPanels.values.map(\.window) + eventLogPanels.values.map(\.window)
            + inventoryPanels.values.map(\.window) {
            window?.close()
        }
        sftpBrowsers?.closeAll()
        await rdpFlow.shutdown()
        let sessions = Array(sshSessions.values)
        sshSessions.removeAll()
        for session in sessions { await session.close() }
    }

    private func restoreSessionAndLoad() {
        guard ProcessInfo.processInfo.environment["IAP_SNAPSHOT"] == nil else {
            Self.log.notice("autoload skipped reason=snapshot \(BuildInfo.current, privacy: .public)")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreSession()
            await self.refreshAccount()
            self.observeSession()
            await self.loadLiveData(trigger: "launch")
        }
    }

    private func restoreSession() async {
        let store = environment.keychainStore()
        guard
            let accounts = try? store.accounts(),
            let first = accounts.first,
            let credential = try? store.load(issuer: first.issuer, email: first.email)
        else { return }
        await credentialFacade.restoreOffline(credential)
    }

    /// `Reauthorized` de ESTA fachada: nunca llega a otro perfil.
    private func observeSession() {
        Task { @MainActor [weak self] in
            guard let stream = await self?.credentialFacade.reauthorized() else { return }
            for await _ in stream {
                guard let self else { return }
                await self.refreshAccount()
                self.onAccountChanged?(self, await self.credentialFacade.currentOffline)
                if await self.credentialFacade.currentEmail != nil {
                    await self.loadLiveData(trigger: "reauthorized")
                } else {
                    self.windowController?.statusNote = ""
                }
            }
        }
    }

    /// Cuenta en la status bar; con varios perfiles, precedida del nombre del perfil.
    private func refreshAccount() async {
        let email = await credentialFacade.currentEmail
        let account: String?
        if showsProfileName() {
            account = "\(descriptor.displayName) · \(email ?? "sin sesión")"
        } else {
            account = email
        }
        windowController?.showAccount(email: account)
    }

    private func loadLiveData(trigger: String) async {
        Self.log.notice("autoload started trigger=\(trigger, privacy: .public) profile=\(self.id.rawValue, privacy: .public) \(BuildInfo.current, privacy: .public)")
        switch await viewModel.reloadAllowingStored(workspace: workspace, stored: knownProjectIDs) {
        case .success(let discovered):
            Self.log.notice("""
                autoload loaded discovered=\(discovered, privacy: .public) \
                projects=\(self.viewModel.projectCount, privacy: .public) \
                instances=\(self.viewModel.instanceCount, privacy: .public) \(BuildInfo.current, privacy: .public)
                """)
            guard !discovered else {
                windowController?.statusNote = ""
                return
            }
            let discoveryFailure = await workspace.lastDiscoveryFailure
            Self.log.error("""
                discovery failed \(discoveryFailure?.logDescription ?? "cause=unknown", privacy: .public) \
                activation=\(discoveryFailure?.activationURL == nil ? "-" : "present", privacy: .public) \
                \(BuildInfo.current, privacy: .public)
                """)
            windowController?.statusNote = ProjectWorkspace.discoveryNote(
                for: discoveryFailure, shown: knownProjectIDs.count)
        case .failure(let error):
            let failure = AppDelegate.diagnose(error)
            let detail = (error as? GoogleAPIFailure).map { " \($0.logDescription)" } ?? ""
            Self.log.error("autoload failed \(failure.logCause, privacy: .public)\(detail, privacy: .public) \(BuildInfo.current, privacy: .public)")
            windowController?.statusNote = failure.userNote
        }
    }

    /// Tenants de ESTE perfil (suite namespaced; el legado sin migrar usa `.standard`).
    var knownProjectIDs: [String] {
        get { explorerDefaults.stringArray(forKey: ProfileEnvironment.knownProjectsKey) ?? [] }
        set { explorerDefaults.set(newValue, forKey: ProfileEnvironment.knownProjectsKey) }
    }

    @objc func addProjectDialog(_ sender: Any?) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "project-id (p. ej. mi-proyecto-123)"
        let alert = NSAlert()
        alert.messageText = "Add project"
        alert.informativeText = "ID del proyecto de Google Cloud (sin permiso de listado se carga directo)."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppDelegate.isValidProjectID(id) else {
            windowController?.statusNote = "ID de proyecto inválido (minúsculas, dígitos, guiones)."
            return
        }
        if !knownProjectIDs.contains(id) {
            knownProjectIDs = knownProjectIDs + [id]
        }
        Task { @MainActor [weak self] in await self?.loadLiveData(trigger: "add-project") }
    }

    // MARK: - Acciones de menú (el AppDelegate las reenvía al perfil del frente)

    @objc func diagnoseSelected(_ sender: Any?) {
        guard let instance = selectedInstance(title: WindowsConnectInterposer.diagnoseTitle) else { return }
        diagnosticsPanels.show(instance)
    }

    @objc func showEventLog(_ sender: Any?) {
        guard let instance = selectedInstance(title: "Show event log") else { return }
        let panel = eventLogPanels[instance.id] ?? EventLogWindowController(instance: instance, client: vmClient)
        eventLogPanels[instance.id] = panel
        panel.showWindow(sender)
    }

    @objc func showSerialPortOutput(_ sender: Any?) {
        guard let instance = selectedInstance(title: "Show serial port output") else { return }
        let panel = serialOutputPanels[instance.id] ?? SerialOutputWindowController(instance: instance, client: vmClient)
        serialOutputPanels[instance.id] = panel
        panel.showWindow(sender)
    }

    private func selectedInstance(title: String) -> InstanceInfo? {
        if let instance = viewModel.selection { return instance }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Selecciona una instancia en Project Explorer."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return nil
    }

    @objc func connectSelected(_ sender: Any?) {
        if let instance = viewModel.selection, instance.os == .windows {
            rdpFlow.connect(instance)
        } else {
            windowController?.connectSelectedInstance(sender)
        }
    }

    @objc func browseSelectedFiles(_ sender: Any?) {
        guard let instance = viewModel.selection, instance.os == .linux else { return }
        sftpBrowsers?.browse(instance)
    }

    /// ⌘W contextual (GH-64) dentro de la ventana de este perfil.
    @objc func closeActiveSessionOrWindow(_ sender: Any?) {
        let key = NSApp.keyWindow
        guard let explorer = windowController?.window, key === explorer, let closeCoordinator else {
            key?.performClose(sender)
            return
        }
        closeCoordinator.closeActiveSessionOrWindow(title: AppDelegate.tabTitle) { explorer.performClose(sender) }
    }

    @objc func signOut(_ sender: Any?) {
        Task { await rdpFlow.shutdown() }
        Task { await credentialFacade.revoke(revokingWith: RevokeClient()) }
    }

    @objc func showLoginWindow(_ sender: Any?) {
        if loginWindowController == nil {
            loginWindowController = LoginWindowController(
                facade: credentialFacade,
                clientID: ProcessInfo.processInfo.environment["GOOGLE_OAUTH_CLIENT_ID"] ?? "",
                clientIDDefaults: clientIDDefaults)
            loginWindowController?.window?.title = "Sign In — \(descriptor.displayName)"
        }
        loginWindowController?.showWindow(sender)
        NSApplication.shared.activate()
    }

    var loginWindow: NSWindow? { loginWindowController?.window }

    @objc func refreshProfileExplorer(_ sender: Any?) {
        Task { @MainActor [weak self] in await self?.loadLiveData(trigger: "refresh") }
    }

    // MARK: - Wiring (igual que antes, con los objetos de este perfil)

    private func wireSshConnect() {
        guard let windowController else { return }
        let tabs = TerminalTabManager(host: windowController.sessionTabs)
        tabs.onSessionEnded = { [weak self] instanceID in
            guard let session = self?.sshSessions.removeValue(forKey: instanceID) else { return }
            if self?.sftpBrowsers?.isUsing(session) == true { return }
            Task { await session.close() }
        }
        terminalTabs = tabs
        wireSessionClose(tabs: tabs, windowController: windowController)
        windowController.onConnectRequest = { [weak self] instance in
            self?.connect(to: instance)
        }
    }

    private func wireRdpConnect() {
        windowsConnect = WindowsConnectInterposer(window: windowController?.window) { [weak self] instance in
            self?.rdpFlow.connect(instance)
        }
        windowsConnect?.onGenerateCredentials = { [weak self] instance in
            self?.rdpFlow.generateCredentials(instance)
        }
        if windowsConnect == nil { RdpConnectFlow.log.error("rdp hookup failed: outline not found") }
        wireSftpBrowse()
    }

    private func wireSftpBrowse() {
        guard let windowController else { return }
        let browsers = SftpBrowsers(
            host: windowController.sessionTabs,
            terminalSession: { [weak self] in self?.sshSessions[$0.id] },
            connect: { [weak self] instance in
                guard let self else { throw SshSessionError.sessionClosed }
                guard await self.credentialFacade.currentEmail != nil else {
                    self.showLoginWindow(nil)
                    throw SshSessionError.sessionClosed
                }
                return try await self.sshConnector.connect(
                    to: SshTarget(project: instance.project, zone: instance.zone, instance: instance.name))
            },
            onFailure: { [weak self] error, instance in
                let failure = error is SftpError
                    ? ConnectionFailure(message: "No se pudo abrir el explorador SFTP.", helpTopic: nil)
                    : ConnectionFailure(error)
                self?.presentConnectionFailure(failure, instance: instance)
            })
        browsers.isTerminalSession = { [weak self] session in
            self?.sshSessions.values.contains { $0 === session } ?? false
        }
        sftpBrowsers = browsers
        windowsConnect?.onBrowseFiles = { [weak browsers] in browsers?.browse($0) }
        windowsConnect?.onDiagnose = { [weak self] in self?.diagnosticsPanels.show($0) }
    }

    private func wireSessionClose(tabs: TerminalTabManager, windowController: ExplorerWindowController) {
        let host = windowController.sessionTabs
        let confirmer = SessionCloseConfirmer.live(tabs: tabs) { [weak self] instanceID in
            self?.sftpBrowsers?.hasActiveTransfer(instanceID: instanceID) ?? false
        }
        let coordinator = SessionCloseCoordinator(
            tabs: tabs, host: host, confirmer: confirmer,
            ask: SessionCloseCoordinator.alertAsk { [weak windowController] in windowController?.window })
        closeCoordinator = coordinator
        host.onCloseRequested = { [weak self, weak host] identifier in
            guard let self else { return }
            if coordinator.isSessionTab(identifier) {
                Task { await coordinator.requestClose(instanceID: identifier, title: AppDelegate.tabTitle(identifier)) }
            } else if self.sftpBrowsers?.isFilesTab(identifier) == true {
                self.sftpBrowsers?.close(identifier)
            } else {
                host?.closeSession(identifier: identifier)
            }
        }
        let closeGuard = WindowCloseGuard(
            shouldClose: { [weak self, weak host] window in
                coordinator.windowShouldClose(
                    hasOtherTabs: !(host?.sessionIdentifiers.allSatisfy(coordinator.isSessionTab) ?? true),
                    closeOthers: { self?.sftpBrowsers?.closeAll() },
                    reclose: { window.close() })
            },
            willClose: { [weak self] in
                guard let self else { return }
                self.onWindowClosed?(self)
            })
        windowCloseGuard = closeGuard
        windowController.window?.delegate = closeGuard
    }

    private func wireVmControl() {
        windowController?.onVmControlRequest = { [weak self] action, instance in
            self?.control(instance, action: action)
        }
    }

    private func wireInventory() {
        windowController?.onSoftwarePackagesRequest = { [weak self] scope in
            guard let self else { return }
            let panel = inventoryPanels[scope.id] ?? InventoryWindowController(scope: scope, client: vmClient)
            inventoryPanels[scope.id] = panel
            panel.showWindow(nil)
        }
    }

    private func control(_ instance: InstanceInfo, action: VmControlAction) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch action {
                case .start:
                    try await vmClient.start(project: instance.project, zone: instance.zone, instance: instance.name)
                case .stop:
                    try await vmClient.stop(project: instance.project, zone: instance.zone, instance: instance.name)
                case .reset:
                    try await vmClient.reset(project: instance.project, zone: instance.zone, instance: instance.name)
                case .suspend:
                    try await vmClient.suspend(project: instance.project, zone: instance.zone, instance: instance.name)
                case .resume:
                    try await vmClient.resume(project: instance.project, zone: instance.zone, instance: instance.name)
                }
                await loadLiveData(trigger: "vmops-refresh")
            } catch {
                presentVmControlFailure(action: action, instance: instance, error: error)
            }
        }
    }

    private func presentVmControlFailure(action: VmControlAction, instance: InstanceInfo, error: any Error) {
        let detail: String
        switch error {
        case GCPClientError.apiError(let status, _):
            detail = "Google Compute respondió con HTTP \(status)."
        case GCPClientError.invalidResponse:
            detail = "Google Compute devolvió una operación inválida o agotó el tiempo de espera."
        default:
            detail = "No se pudo completar la solicitud a Google Compute."
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No se pudo ejecutar \(action.title) en \(instance.name)"
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window = windowController?.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func connect(to instance: InstanceInfo) {
        guard let tabs = terminalTabs, !connecting.contains(instance.id) else { return }
        if let view = tabs.view(for: instance.id), !view.hasEnded,
           let session = sshSessions[instance.id] {
            Task { _ = try? await tabs.openShell(instanceID: instance.id, title: instance.name, session: session) }
            return
        }
        connecting.insert(instance.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.connecting.remove(instance.id) }
            guard await self.credentialFacade.currentEmail != nil else {
                self.showLoginWindow(nil)
                return
            }
            let target = SshTarget(project: instance.project, zone: instance.zone, instance: instance.name)
            do {
                let session = try await self.sshConnector.connect(to: target)
                self.sshSessions[instance.id] = session
                do {
                    _ = try await tabs.openShell(instanceID: instance.id, title: instance.name, session: session)
                } catch {
                    self.sshSessions[instance.id] = nil
                    await session.close()
                    throw error
                }
            } catch {
                self.presentConnectionFailure(ConnectionFailure(error), instance: instance)
            }
        }
    }

    private func presentConnectionFailure(_ failure: ConnectionFailure, instance: InstanceInfo) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No se pudo conectar a \(instance.name)"
        alert.informativeText = failure.message
        alert.addButton(withTitle: "OK")
        if let help = failure.helpTopic {
            alert.addButton(withTitle: help.title)
        }
        let openHelp: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn, let help = failure.helpTopic {
                NSWorkspace.shared.open(help.url)
            }
        }
        if let window = windowController?.window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { openHelp(response) }
            }
        } else {
            openHelp(alert.runModal())
        }
    }

    private func wireRefreshAction() {
        let refreshID = NSToolbarItem.Identifier("iap.refresh")
        guard let refreshItem = windowController?.window?.toolbar?.items.first(where: {
            $0.itemIdentifier == refreshID
        }) else { return }
        refreshItem.target = self
        refreshItem.action = #selector(refreshProfileExplorer(_:))
    }
}
