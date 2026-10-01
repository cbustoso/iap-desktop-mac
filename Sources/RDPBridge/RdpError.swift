import Foundation

/// Errores del fallback `.rdp` (T-RDP-1). El resto de casos del diseño
/// (FreeRDP, reset de credenciales) llegan con sus tareas.
public enum RdpError: Error, Equatable, Sendable {
    /// "Windows App" (antes "Microsoft Remote Desktop") no está instalada.
    case windowsAppNotInstalled(help: URL)
    /// `NSWorkspace` no pudo abrir el `.rdp` (motivo sin datos de la sesión).
    case launchFailed(reason: String)
    /// Usuario/dominio con caracteres que romperían el formato `.rdp`
    /// (saltos de línea): se rechaza en vez de inyectar claves.
    case invalidCredentialField(String)

    /// Página de la App Store de "Windows App" (mismo id que el antiguo
    /// "Microsoft Remote Desktop").
    public static let windowsAppHelp = URL(string: "https://apps.apple.com/app/windows-app/id1295203466")!
}
