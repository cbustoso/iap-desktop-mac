import AppKit
import AuthKit
import ExplorerUI
import GCPClient
import OSLog
import RDPBridge

/// Punto de entrada AppKit (sin SwiftUI: esta máquina compila con CLT).
///
/// GH-72: el delegado ya no es "la sesión": posee un `ProfileCoordinator` con
/// una `ProfileSession` (fachada, GCPClient, ventana, pestañas, SSH/RDP/SFTP)
/// por perfil abierto. Las acciones de menú se reenvían al perfil del frente.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var coordinator: ProfileCoordinator!
    private let profilesMenu = NSMenu(title: "Profiles")

    nonisolated static let log = Logger(subsystem: "com.iapdesktop.mac", category: "login")

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
        // REQ-MT-5: migración una sola vez, antes de abrir ningún perfil. En
        // modo snapshot no se toca Keychain: perfil legado sin restaurar.
        let snapshot = ProcessInfo.processInfo.environment["IAP_SNAPSHOT"] != nil
        let migrator = ProfileMigrator()
        if !snapshot { migrator.migrateLegacySingleProfileIfNeeded() }
        coordinator = ProfileCoordinator(migrationCompleted: !snapshot && migrator.isCompleted)
        coordinator.activate(snapshot ? .legacyDefault : coordinator.initialProfile)
        app.activate()
        snapshotIfRequested()
    }

    private var front: ProfileSession? { coordinator?.frontSession }

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

    /// `project/zone/instance` → `instance`.
    nonisolated static func tabTitle(_ identifier: String) -> String {
        identifier.split(separator: "/").last.map(String.init) ?? identifier
    }

    /// Solo tooling (`tools/snapshot.sh`): con `IAP_SNAPSHOT=<png>` renderiza la
    /// ventana (incluida la toolbar) a PNG y sale. `IAP_SNAPSHOT_SELECT=<node id>`
    /// preselecciona un nodo y `IAP_SNAPSHOT_APPEARANCE=light|dark` fija la apariencia.
    private func snapshotIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["IAP_SNAPSHOT"], let session = front else { return }
        switch env["IAP_SNAPSHOT_APPEARANCE"] {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let id = env["IAP_SNAPSHOT_SELECT"] { session.windowController?.selectNode(id: id) }
        // IAP_SNAPSHOT_LOGIN=1 captura la ventana Sign In en vez de la principal.
        let target: NSWindow? = env["IAP_SNAPSHOT_LOGIN"] == "1"
            ? { session.showLoginWindow(nil); return session.loginWindow }()
            : session.window
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

    /// ⌘Q (GH-64): cada ventana con pestañas pasa por su propio cierre
    /// (confirmación + limpieza de SU perfil); al cerrarse la última, la app termina.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sessions = coordinator?.openSessions ?? []
        guard sessions.contains(where: { $0.hasOpenTabs && $0.window?.isVisible == true }) else { return .terminateNow }
        for session in sessions { session.window?.performClose(nil) }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Los túneles mueren con el proceso; los .rdp (usuario, sin contraseña) se borran.
    func applicationWillTerminate(_ notification: Notification) {
        RdpFallbackConnector.removeGeneratedFiles()
    }

    // MARK: - Menú principal (File/Session/View/Tools/Profiles/Window/Help)

    private func installMenu() {
        let app = NSApplication.shared
        let mainMenu = NSMenu()

        let appName = "IAP Desktop Mac"
        mainMenu.addItem(submenu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            forwarding("Sign In…", #selector(showLoginWindow(_:))),
            forwarding("Sign Out", #selector(signOut(_:))),
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
            forwarding("Close Window", #selector(closeActiveSessionOrWindow(_:)), key: "w"),
        ]))

        mainMenu.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), key: "z"),
            item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), key: "x"),
            item("Copy", #selector(NSText.copy(_:)), key: "c"),
            item("Paste", #selector(NSText.paste(_:)), key: "v"),
            item("Select All", #selector(NSText.selectAll(_:)), key: "a"),
        ]))

        mainMenu.addItem(submenu("Session", [
            forwarding("Connect", #selector(connectSelected(_:))),
            forwarding(WindowsConnectInterposer.browseFilesTitle, #selector(browseSelectedFiles(_:))),
            forwarding("Show serial port output", #selector(showSerialPortOutput(_:))),
            forwarding(WindowsConnectInterposer.diagnoseTitle, #selector(diagnoseSelected(_:))),
            forwarding("Show event log", #selector(showEventLog(_:))),
            pending("Connect as user…", milestone: "M2"),
            pending("Connection settings…", milestone: "M2"),
        ]))

        mainMenu.addItem(submenu("View", [
            forwarding("Refresh", #selector(refreshExplorer(_:)), key: "r"),
            item("Show/Hide Properties", #selector(ExplorerWindowController.toggleProperties(_:)),
                 key: "p", modifiers: [.command, .option]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f",
                 modifiers: [.command, .control]),
        ]))

        mainMenu.addItem(submenu("Tools", [
            item("Options…", #selector(ExplorerWindowController.openSettings(_:))),
        ]))

        // GH-72: lista dinámica de perfiles (se reconstruye al abrir el menú).
        profilesMenu.delegate = self
        let profilesHolder = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
        profilesHolder.submenu = profilesMenu
        mainMenu.addItem(profilesHolder)

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

    // MARK: - Menú Profiles (T-MT-5)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === profilesMenu, let coordinator else { return }
        menu.removeAllItems()
        for item in Self.profileItems(coordinator.profiles, open: Set(coordinator.openSessions.map(\.id)),
                                       front: front?.id, target: self, action: #selector(selectProfile(_:))) {
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add profile…", action: #selector(addProfile(_:)), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let remove = NSMenuItem(title: "Remove profile", action: nil, keyEquivalent: "")
        let removeMenu = NSMenu(title: "Remove profile")
        for profile in coordinator.profiles {
            let entry = NSMenuItem(title: profile.displayName + "…", action: #selector(removeProfile(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = profile.id.rawValue
            removeMenu.addItem(entry)
        }
        remove.submenu = removeMenu
        menu.addItem(remove)
    }

    /// Un ítem por perfil: nombre + cuenta redactada (o "sin sesión"), ✓ si
    /// está abierto. `representedObject` = `profileID`.
    static func profileItems(
        _ profiles: [ProfileDescriptor], open: Set<ProfileID>, front: ProfileID?, target: AnyObject?, action: Selector
    ) -> [NSMenuItem] {
        profiles.map { profile in
            let account = profile.redactedAccount ?? "sin sesión"
            let item = NSMenuItem(title: "\(profile.displayName) — \(account)", action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = profile.id.rawValue
            item.state = profile.id == front ? .on : (open.contains(profile.id) ? .mixed : .off)
            return item
        }
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ProfileID(rawValue: raw) else { return }
        coordinator.activate(id)
    }

    @objc private func addProfile(_ sender: Any?) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Nombre del perfil (p. ej. Cliente A)"
        let alert = NSAlert()
        alert.messageText = "Add profile"
        alert.informativeText = "Cada perfil tiene su propia cuenta, client OAuth, proyectos y Keychain."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.createProfile(named: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func removeProfile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ProfileID(rawValue: raw),
              let profile = coordinator.profiles.first(where: { $0.id == id })
        else { return }
        if coordinator.isOpen(id) {
            let alert = NSAlert()
            alert.messageText = "Cierra primero la ventana de \(profile.displayName)"
            alert.informativeText = "Así sus sesiones SSH/RDP/SFTP se cierran con su confirmación habitual."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let confirm = NSAlert()
        confirm.alertStyle = .critical
        confirm.messageText = "¿Eliminar el perfil \(profile.displayName)?"
        confirm.informativeText = "Se borran su sesión, su client OAuth propio, sus proyectos y sus credenciales "
            + "guardadas. No se puede deshacer."
        confirm.addButton(withTitle: "Remove")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            try coordinator.removeProfile(id)
        } catch {
            let failure = NSAlert()
            failure.messageText = "No se pudo eliminar el perfil"
            failure.informativeText = "\(error)"
            failure.runModal()
        }
    }

    // MARK: - Reenvío al perfil del frente

    @objc private func showLoginWindow(_ sender: Any?) { front?.showLoginWindow(sender) }
    @objc private func signOut(_ sender: Any?) { front?.signOut(sender) }
    @objc private func connectSelected(_ sender: Any?) { front?.connectSelected(sender) }
    @objc private func browseSelectedFiles(_ sender: Any?) { front?.browseSelectedFiles(sender) }
    @objc private func showSerialPortOutput(_ sender: Any?) { front?.showSerialPortOutput(sender) }
    @objc private func diagnoseSelected(_ sender: Any?) { front?.diagnoseSelected(sender) }
    @objc private func showEventLog(_ sender: Any?) { front?.showEventLog(sender) }
    @objc private func refreshExplorer(_ sender: Any?) { front?.refreshProfileExplorer(sender) }

    /// ⌘W: si la ventana clave es de un perfil, su lógica contextual; si no,
    /// cerrar la ventana clave como siempre.
    @objc private func closeActiveSessionOrWindow(_ sender: Any?) {
        if let session = coordinator?.openSessions.first(where: { $0.window === NSApp.keyWindow }) {
            session.closeActiveSessionOrWindow(sender)
        } else {
            NSApp.keyWindow?.performClose(sender)
        }
    }

    private func forwarding(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = item(title, action, key: key)
        menuItem.target = self
        return menuItem
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

/// Delegado de la ventana del Explorer: `windowShouldClose` (GH-64) y aviso de
/// cierre para liberar la `ProfileSession` del perfil (GH-72).
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private let shouldClose: @MainActor (NSWindow) -> Bool
    private let willClose: @MainActor () -> Void

    init(shouldClose: @escaping @MainActor (NSWindow) -> Bool, willClose: @escaping @MainActor () -> Void = {}) {
        self.shouldClose = shouldClose
        self.willClose = willClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose(sender) }
    func windowWillClose(_ notification: Notification) { willClose() }
}
