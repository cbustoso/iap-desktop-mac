import AppKit

/// Lo que `WindowsAppLauncher` necesita de `NSWorkspace` (inyectable en tests).
@MainActor
public protocol WorkspaceOpening {
    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL?
    func open(_ fileURL: URL, withApplicationAt applicationURL: URL) async throws
}

extension NSWorkspace: WorkspaceOpening {
    public func open(_ fileURL: URL, withApplicationAt applicationURL: URL) async throws {
        _ = try await open([fileURL], withApplicationAt: applicationURL, configuration: OpenConfiguration())
    }
}

/// Abre un `.rdp` con "Windows App" (fallback T-RDP-1, REQ-RDP-2). No controla
/// la sesión: solo verifica que el lanzamiento tuvo éxito.
@MainActor
public struct WindowsAppLauncher {
    /// Bundle id de "Windows App" 11.x y del antiguo "Microsoft Remote Desktop" 10.
    public static let bundleIdentifier = "com.microsoft.rdc.macos"

    private let workspace: any WorkspaceOpening

    public init(workspace: any WorkspaceOpening = NSWorkspace.shared) {
        self.workspace = workspace
    }

    /// Ruta de "Windows App", o `nil` si no está instalada.
    public var applicationURL: URL? {
        workspace.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    }

    public func open(_ fileURL: URL) async throws(RdpError) {
        guard let applicationURL else {
            throw .windowsAppNotInstalled(help: RdpError.windowsAppHelp)
        }
        do {
            try await workspace.open(fileURL, withApplicationAt: applicationURL)
        } catch {
            // Solo dominio y código: la descripción podría incluir la ruta del .rdp.
            let nsError = error as NSError
            throw .launchFailed(reason: "\(nsError.domain) \(nsError.code)")
        }
    }
}
