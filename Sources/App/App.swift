import AppKit
import ExplorerUI

/// Punto de entrada AppKit (sin SwiftUI: esta máquina compila con CLT).
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: ExplorerWindowController?

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
        windowController = ExplorerWindowController(viewModel: viewModel)
        windowController?.showWindow(nil)
        app.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            NSMenuItem(
                title: "Quit IAP Desktop Mac",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
        NSApplication.shared.mainMenu = mainMenu
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
