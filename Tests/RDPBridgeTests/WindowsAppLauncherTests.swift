import AppKit
import Testing
@testable import RDPBridge

@MainActor
private final class FakeWorkspace: WorkspaceOpening {
    var installedAt: URL?
    var failure: (any Error)?
    private(set) var opened: [(file: URL, app: URL)] = []

    init(installedAt: URL?, failure: (any Error)? = nil) {
        self.installedAt = installedAt
        self.failure = failure
    }

    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        bundleIdentifier == WindowsAppLauncher.bundleIdentifier ? installedAt : nil
    }

    func open(_ fileURL: URL, withApplicationAt applicationURL: URL) async throws {
        if let failure { throw failure }
        opened.append((fileURL, applicationURL))
    }
}

private let app = URL(fileURLWithPath: "/Applications/Windows App.app")
private let file = URL(fileURLWithPath: "/tmp/x.rdp")

@Suite("WindowsAppLauncher (CBU-49)")
@MainActor
struct WindowsAppLauncherTests {
    @Test func missingWindowsAppThrowsTypedError() async {
        let launcher = WindowsAppLauncher(workspace: FakeWorkspace(installedAt: nil))
        #expect(launcher.applicationURL == nil)
        await #expect(throws: RdpError.windowsAppNotInstalled(help: RdpError.windowsAppHelp)) {
            try await launcher.open(file)
        }
    }

    @Test func opensFileWithWindowsApp() async throws {
        let workspace = FakeWorkspace(installedAt: app)
        try await WindowsAppLauncher(workspace: workspace).open(file)
        #expect(workspace.opened.map(\.file) == [file])
        #expect(workspace.opened.map(\.app) == [app])
    }

    @Test func launchFailureHidesDescription() async {
        let error = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [NSFilePathErrorKey: "/secret/x.rdp"])
        let launcher = WindowsAppLauncher(workspace: FakeWorkspace(installedAt: app, failure: error))
        await #expect(throws: RdpError.launchFailed(reason: "NSCocoaErrorDomain 260")) {
            try await launcher.open(file)
        }
    }

    // En esta máquina está instalada: el bundle id resuelve a la ruta real.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/Windows App.app")))
    func realWorkspaceFindsInstalledWindowsApp() {
        let url = WindowsAppLauncher().applicationURL
        #expect(url?.lastPathComponent == "Windows App.app")
    }
}
