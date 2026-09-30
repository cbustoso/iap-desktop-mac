import AppKit
import AuthKit
import ExplorerUI

/// Punto de entrada AppKit (sin SwiftUI: esta máquina compila con CLT).
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: ExplorerWindowController?
    private var loginWindowController: LoginWindowController?
    private let credentialFacade = CredentialFacade()

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
        let viewModel = ExplorerViewModel(projects: MockWorkspace.sample())
        windowController = ExplorerWindowController(viewModel: viewModel, dataSourceLabel: "MOCK")
        windowController?.showWindow(nil)
        app.activate()
        snapshotIfRequested()
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
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if let frame = windowController?.window?.contentView?.superview,
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

    // MARK: - Menú principal (File/Session/View/Tools/Window/Help como el original)

    private func installMenu() {
        let app = NSApplication.shared
        let mainMenu = NSMenu()

        let appName = "IAP Desktop Mac"
        mainMenu.addItem(submenu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            signInItem(),
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
            pending("Connect", milestone: "M1"),
            pending("Connect as user…", milestone: "M2"),
            pending("Connection settings…", milestone: "M2"),
        ]))

        mainMenu.addItem(submenu("View", [
            item("Refresh", #selector(ExplorerWindowController.refreshExplorer(_:)), key: "r"),
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

    @objc private func showLoginWindow(_ sender: Any?) {
        if loginWindowController == nil {
            loginWindowController = LoginWindowController(
                facade: credentialFacade,
                clientID: ProcessInfo.processInfo.environment["GOOGLE_OAUTH_CLIENT_ID"] ?? "")
        }
        loginWindowController?.showWindow(sender)
        NSApplication.shared.activate()
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

/// Datos de ejemplo. SUSTITUIR por ProjectWorkspace+GCPClient (T-EXP-1/2).
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
