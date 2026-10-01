import AppKit
import AuthKit
import OSLog
import RDPBridge
import ExplorerUI
import GCPClient
import SSHKit
import TerminalUI
import TunnelKit

/// Punto de entrada AppKit (sin SwiftUI: esta máquina compila con CLT).
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: ExplorerWindowController?
    private var loginWindowController: LoginWindowController?
    private var settingsPanelController: SettingsPanelWindowController?
    private let credentialFacade = CredentialFacade()
    private let viewModel = ExplorerViewModel(projects: MockWorkspace.sample())

    /// Tokens reales vía fachada (con refresh automático). Al arrancar sin
    /// sesión expira al primer uso y el árbol conserva el mock (fallback).
    private lazy var workspace = ProjectWorkspace(client: GCPClient(tokenProvider: accessToken))
    private lazy var vmClient = GCPClient(tokenProvider: accessToken)

    /// Token OAuth de la sesión activa (refresh automático vía fachada).
    /// Compartido por Compute, OS Login y el túnel IAP; nunca se registra.
    private lazy var accessToken: @Sendable () async throws -> String = {
        let facade = self.credentialFacade
        return {
            // Token vigente: sin refresh, sin traza.
            if let token = try? await facade.validAccessToken() { return token }
            let store = ClientIDStore()
            do {
                // Nunca `client_id` vacío (antes `?? ""`): Google respondía
                // "Could not determine client ID from request" (CBU-28e).
                guard let clientID = try? store.resolve() else { throw AuthError.clientNotConfigured }
                let token = try await TokenRefresher().refreshedAccessToken(
                    facade: facade,
                    client: TokenClient(clientID: clientID, clientSecret: store.clientSecret()))
                AppDelegate.log.notice("token refresh succeeded \(BuildInfo.current, privacy: .public)")
                return token
            } catch {
                // Sin tokens ni codes: solo la causa clasificada.
                AppDelegate.log.error("""
                    token refresh failed \(AppDelegate.diagnose(error).logCause, privacy: .public) \
                    \(BuildInfo.current, privacy: .public)
                    """)
                throw error
            }
        }
    }()

    /// Traza de login, refresh y auto-carga (subsystem existente, categoría login).
    nonisolated static let log = Logger(subsystem: "com.iapdesktop.mac", category: "login")

    // MARK: SSH vía IAP (CBU-44)

    /// Host keys aceptadas en esta ejecución (TOFU provisional hasta T-SSH-7).
    private let knownHosts = InMemoryKnownHosts()
    private var terminalTabs: TerminalTabManager?
    /// Conexión SSH de cada pestaña (se cierra al terminar o cerrar la pestaña).
    private var sshSessions: [String: SshSession] = [:]
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
            email: { await facade.currentEmail },
            window: { [weak self] in self?.windowController?.window },
            note: { [weak self] in self?.windowController?.statusNote = $0 })
    }()
    private var windowsConnect: WindowsConnectInterposer?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        windowController = ExplorerWindowController(viewModel: viewModel, dataSourceLabel: "MOCK")
        windowController?.onAddProject = { [weak self] in self?.addProjectDialog(nil) }
        let settingsDataSource = ApplicationSettingsDataSource { [weak self] in
            self?.viewModel.projects ?? []
        }
        let settingsPanel = SettingsPanelWindowController(dataSource: settingsDataSource)
        settingsPanelController = settingsPanel
        windowController?.onOpenSettings = { [weak settingsPanel] scope in
            settingsPanel?.show(preferredScope: scope)
        }
        wireSshConnect()
        wireVmControl()
        wireRdpConnect()
        windowController?.showWindow(nil)
        wireRefreshAction()
        app.activate()
        restoreSessionAndLoad()
        snapshotIfRequested()
    }

    /// Como el IAP original: al arrancar restaura la sesión del Keychain y
    /// carga proyectos/instancias automáticamente; tras cada login/logout
    /// (evento Reauthorized) recarga si hay sesión. Sin sesión o con fallo,
    /// el árbol conserva el mock visible.
    private func restoreSessionAndLoad() {
        // Modo snapshot (tools/snapshot.sh, SnapshotSmokeTests): sin Keychain
        // ni red. Antes cada `swift test` restauraba la sesión real del
        // usuario e intentaba un refresh desde el binario suelto (CBU-28e).
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
        let store = KeychainStore()
        guard
            let accounts = try? store.accounts(),
            let first = accounts.first,
            let credential = try? store.load(issuer: first.issuer, email: first.email)
        else { return }
        await credentialFacade.restoreOffline(credential)
    }

    private func observeSession() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in await self.credentialFacade.reauthorized() {
                await self.refreshAccount()
                if await self.credentialFacade.currentEmail != nil {
                    await self.loadLiveData(trigger: "reauthorized")
                } else {
                    // Logout: la nota hablaba de la sesión anterior.
                    self.windowController?.statusNote = ""
                }
            }
        }
    }

    /// Cuenta en la status bar (email completo en la UI; en logs solo dominio).
    private func refreshAccount() async {
        windowController?.showAccount(email: await credentialFacade.currentEmail)
    }

    /// Auto-carga de proyectos e instancias. Deja traza del resultado y, si
    /// falla (401, IAM, red…), lo muestra en la status bar en vez de dejar el
    /// mock en silencio. Sin permiso para listar (403), usa los proyectos
    /// añadidos manualmente (paridad: picker Add project del original).
    private func loadLiveData(trigger: String) async {
        Self.log.notice("autoload started trigger=\(trigger, privacy: .public) \(BuildInfo.current, privacy: .public)")
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
            // CBU-47b: el motivo del 403 ya no se traga en el fallback.
            let discoveryFailure = await workspace.lastDiscoveryFailure
            Self.log.error("""
                discovery failed \(discoveryFailure?.logDescription ?? "cause=unknown", privacy: .public) \
                activation=\(discoveryFailure?.activationURL == nil ? "-" : "present", privacy: .public) \
                \(BuildInfo.current, privacy: .public)
                """)
            windowController?.statusNote = ProjectWorkspace.discoveryNote(
                for: discoveryFailure, shown: knownProjectIDs.count)
        case .failure(let error):
            let failure = Self.diagnose(error)
            let detail = (error as? GoogleAPIFailure).map { " \($0.logDescription)" } ?? ""
            Self.log.error("autoload failed \(failure.logCause, privacy: .public)\(detail, privacy: .public) \(BuildInfo.current, privacy: .public)")
            windowController?.statusNote = failure.userNote
        }
    }

    /// IDs añadidos a mano (File → Add project…), persistidos entre arranques.
    /// Cubren cuentas sin `resourcemanager.projects.list` (403 en discovery).
    private var knownProjectIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "knownProjectIDs") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "knownProjectIDs") }
    }

    /// Diálogo Add project (paridad con el picker del IAP original).
    @objc private func addProjectDialog(_ sender: Any?) {
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
        guard Self.isValidProjectID(id) else {
            windowController?.statusNote = "ID de proyecto inválido (minúsculas, dígitos, guiones)."
            return
        }
        if !knownProjectIDs.contains(id) {
            knownProjectIDs = knownProjectIDs + [id]
        }
        Task { @MainActor [weak self] in await self?.loadLiveData(trigger: "add-project") }
    }

    nonisolated static func isValidProjectID(_ id: String) -> Bool {
        guard (6...30).contains(id.count) else { return false }
        return id.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
            && id.first?.isLetter == true
    }

    /// Clasifica un error de la cadena token → Compute sin exponer su contenido.
    nonisolated static func diagnose(_ error: any Error) -> AutoLoadFailure {
        var status: Int?
        var reason: String?
        if case GCPClientError.apiError(let code, let apiReason) = error {
            status = code
            reason = apiReason
        } else if let failure = error as? GoogleAPIFailure {
            status = failure.status
            reason = failure.reason
        }
        return AutoLoadFailure(
            httpStatus: status,
            reason: reason,
            urlErrorCode: (error as? URLError)?.code.rawValue,
            authError: error as? AuthError,
            typeName: String(describing: type(of: error)))
    }

    /// Solo tooling (`tools/snapshot.sh`): con `IAP_SNAPSHOT=<png>` renderiza la
    /// ventana (incluida la toolbar) a PNG y sale. No necesita permiso de
    /// grabación de pantalla. `IAP_SNAPSHOT_SELECT=<node id>` preselecciona un nodo y
    /// `IAP_SNAPSHOT_APPEARANCE=light|dark` fija la apariencia.
    private func snapshotIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["IAP_SNAPSHOT"] else { return }
        // Solo en snapshot se fuerza apariencia; en uso normal manda el sistema.
        switch env["IAP_SNAPSHOT_APPEARANCE"] {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let id = env["IAP_SNAPSHOT_SELECT"] { windowController?.selectNode(id: id) }
        // IAP_SNAPSHOT_LOGIN=1 captura la ventana Sign In en vez de la principal.
        let target: NSWindow? = env["IAP_SNAPSHOT_LOGIN"] == "1"
            ? { showLoginWindow(nil); return loginWindowController?.window }()
            : windowController?.window
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if let frame = target?.contentView?.superview,
               let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
            }
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Los túneles mueren con el proceso; los .rdp (usuario, sin contraseña) se borran.
    func applicationWillTerminate(_ notification: Notification) {
        RdpFallbackConnector.removeGeneratedFiles()
    }

    // MARK: - Menú principal (File/Session/View/Tools/Window/Help como el original)

    private func installMenu() {
        let app = NSApplication.shared
        let mainMenu = NSMenu()

        let appName = "IAP Desktop Mac"
        mainMenu.addItem(submenu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            signInItem(),
            signOutItem(),
            item("Settings…", #selector(ExplorerWindowController.openSettings(_:)), key: ","),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), key: "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), key: "q"),
        ]))

        mainMenu.addItem(submenu("File", [
            item("Add project…", #selector(ExplorerWindowController.addProject(_:)), key: "n"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), key: "w"),
        ]))

        // Edit: necesario para copiar/pegar en el filtro.
        mainMenu.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), key: "z"),
            item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), key: "x"),
            item("Copy", #selector(NSText.copy(_:)), key: "c"),
            item("Paste", #selector(NSText.paste(_:)), key: "v"),
            item("Select All", #selector(NSText.selectAll(_:)), key: "a"),
        ]))

        // Session: conexión llega en M1 (SSH) / M2 (RDP); sin acción → deshabilitado.
        mainMenu.addItem(submenu("Session", [
            connectItem(),
            pending("Connect as user…", milestone: "M2"),
            pending("Connection settings…", milestone: "M2"),
        ]))

        let refreshItem = item("Refresh", #selector(refreshExplorer(_:)), key: "r")
        refreshItem.target = self
        mainMenu.addItem(submenu("View", [
            refreshItem,
            item("Show/Hide Properties", #selector(ExplorerWindowController.toggleProperties(_:)),
                 key: "p", modifiers: [.command, .option]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f",
                 modifiers: [.command, .control]),
        ]))

        mainMenu.addItem(submenu("Tools", [
            item("Options…", #selector(ExplorerWindowController.openSettings(_:))),
        ]))

        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        mainMenu.addItem(windowMenu)
        app.windowsMenu = windowMenu.submenu

        let helpMenu = submenu("Help", [
            item("\(appName) Help", #selector(NSApplication.showHelp(_:)), key: "?"),
        ])
        mainMenu.addItem(helpMenu)
        app.helpMenu = helpMenu.submenu

        app.mainMenu = mainMenu
    }

    private func signInItem() -> NSMenuItem {
        let menuItem = item("Sign In…", #selector(showLoginWindow(_:)))
        menuItem.target = self
        return menuItem
    }

    /// REQ-AUTH-3 en producto: cierra sesión revocando en el servidor
    /// (best-effort dentro de la fachada). Re-review R2 #5.
    /// Session > Connect: Windows → RDP; el resto, al Explorer (SSH).
    private func connectItem() -> NSMenuItem {
        let menuItem = item("Connect", #selector(connectSelected(_:)))
        menuItem.target = self
        return menuItem
    }

    @objc private func connectSelected(_ sender: Any?) {
        if let instance = viewModel.selection, instance.os == .windows {
            rdpFlow.connect(instance)
        } else {
            windowController?.connectSelectedInstance(sender)
        }
    }

    private func signOutItem() -> NSMenuItem {
        let menuItem = item("Sign Out", #selector(signOut(_:)))
        menuItem.target = self
        return menuItem
    }

    // MARK: - SSH: doble clic / Connect → pestaña con shell

    private func wireSshConnect() {
        guard let windowController else { return }
        let tabs = TerminalTabManager(host: windowController.sessionTabs)
        tabs.onSessionEnded = { [weak self] instanceID in
            guard let session = self?.sshSessions.removeValue(forKey: instanceID) else { return }
            Task { await session.close() }
        }
        terminalTabs = tabs
        windowController.onConnectRequest = { [weak self] instance in
            self?.connect(to: instance)
        }
    }

    /// Doble clic y menú contextual en VMs Windows → RDP (ExplorerUI solo cablea Linux).
    private func wireRdpConnect() {
        windowsConnect = WindowsConnectInterposer(window: windowController?.window) { [weak self] instance in
            self?.rdpFlow.connect(instance)
        }
        if windowsConnect == nil { RdpConnectFlow.log.error("rdp hookup failed: outline not found") }
    }

    private func wireVmControl() {
        windowController?.onVmControlRequest = { [weak self] action, instance in
            self?.control(instance, action: action)
        }
    }

    private func control(_ instance: InstanceInfo, action: VmControlAction) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch action {
                case .start:
                    try await vmClient.start(
                        project: instance.project, zone: instance.zone, instance: instance.name)
                case .stop:
                    try await vmClient.stop(
                        project: instance.project, zone: instance.zone, instance: instance.name)
                case .reset:
                    try await vmClient.reset(
                        project: instance.project, zone: instance.zone, instance: instance.name)
                case .suspend:
                    try await vmClient.suspend(
                        project: instance.project, zone: instance.zone, instance: instance.name)
                case .resume:
                    try await vmClient.resume(
                        project: instance.project, zone: instance.zone, instance: instance.name)
                }
                await loadLiveData(trigger: "vmops-refresh")
            } catch {
                presentVmControlFailure(action: action, instance: instance, error: error)
            }
        }
    }

    private func presentVmControlFailure(
        action: VmControlAction, instance: InstanceInfo, error: any Error
    ) {
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
        // Pestaña viva: solo se selecciona (una por instancia).
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

    /// Error visible con enlace de ayuda (paridad `HelpTopics`); sin secretos.
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

    @objc private func signOut(_ sender: Any?) {
        Task { await rdpFlow.shutdown() }
        Task {
            await credentialFacade.revoke(revokingWith: RevokeClient())
        }
    }

    @objc private func showLoginWindow(_ sender: Any?) {
        if loginWindowController == nil {
            loginWindowController = LoginWindowController(
                facade: credentialFacade,
                clientID: ProcessInfo.processInfo.environment["GOOGLE_OAUTH_CLIENT_ID"] ?? "")
        }
        loginWindowController?.showWindow(sender)
        NSApplication.shared.activate()
    }

    private func wireRefreshAction() {
        let refreshID = NSToolbarItem.Identifier("iap.refresh")
        guard let refreshItem = windowController?.window?.toolbar?.items.first(where: {
            $0.itemIdentifier == refreshID
        }) else { return }
        refreshItem.target = self
        refreshItem.action = #selector(refreshExplorer(_:))
    }

    @objc private func refreshExplorer(_ sender: Any?) {
        Task { @MainActor [weak self] in
            await self?.loadLiveData(trigger: "refresh")
        }
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    /// Target `nil`: la acción viaja por la responder chain hasta la ventana
    /// activa (y su `ExplorerWindowController`).
    private func item(
        _ title: String, _ action: Selector, key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func pending(_ title: String, milestone: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.badge = NSMenuItemBadge(string: milestone)
        item.toolTip = "Disponible en \(milestone)"
        return item
    }
}

/// Fallback visible mientras no haya credenciales o una carga GCP falle.
enum MockWorkspace {
    static func sample() -> [ProjectInfo] {
        [
            ProjectInfo(name: "demo-web (MOCK)", zones: [
                ZoneInfo(project: "demo-web", name: "europe-west1-b", instances: [
                    InstanceInfo(
                        project: "demo-web", zone: "europe-west1-b", name: "web-01",
                        os: .linux, status: .running, connected: true),
                    InstanceInfo(
                        project: "demo-web", zone: "europe-west1-b", name: "web-02",
                        os: .linux, status: .running),
                    InstanceInfo(
                        project: "demo-web", zone: "europe-west1-b", name: "adsrv-01",
                        os: .windows, status: .stopped),
                ]),
                ZoneInfo(project: "demo-web", name: "europe-west1-c", instances: [
                    InstanceInfo(
                        project: "demo-web", zone: "europe-west1-c", name: "db-01",
                        os: .linux, status: .running),
                ]),
            ]),
            ProjectInfo(name: "demo-data (MOCK)", zones: [
                ZoneInfo(project: "demo-data", name: "us-central1-a", instances: [
                    InstanceInfo(
                        project: "demo-data", zone: "us-central1-a", name: "etl-01",
                        os: .linux, status: .stopped),
                    InstanceInfo(
                        project: "demo-data", zone: "us-central1-a", name: "win-bastion",
                        os: .windows, status: .running),
                ]),
            ]),
        ]
    }
}
