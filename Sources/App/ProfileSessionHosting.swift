import AppKit
import AuthKit

/// GH-91 (specs/azure T-AZ-6): lo que el `ProfileCoordinator` y el
/// `AppDelegate` necesitan de la sesión de un perfil, sea de la nube que sea.
/// `ProfileSession` (Google) y `AzureProfileSession` (sesión `az login`) lo
/// implementan; el coordinador elige cuál crear según `ProfileDescriptor.provider`.
@MainActor
protocol ProfileSessionHosting: AnyObject {
    var id: ProfileID { get }
    var descriptor: ProfileDescriptor { get }
    var provider: CloudProvider { get }

    /// Ventana principal del perfil (Explorer Google o ventana Azure).
    var window: NSWindow? { get }
    /// Ventana Sign In, si el proveedor tiene una propia (Azure no: usa `az login`).
    var loginWindow: NSWindow? { get }
    /// ¿Hay pestañas de sesión abiertas? (⌘Q pide confirmación por ventana).
    var hasOpenTabs: Bool { get }

    /// ¿Hay más de un perfil? Entonces la ventana antepone el nombre del perfil.
    var showsProfileName: @MainActor () -> Bool { get set }
    /// La ventana se cerró (tras limpiar lo suyo): el coordinador la libera.
    var onWindowClosed: (@MainActor (any ProfileSessionHosting) -> Void)? { get set }

    /// Ventanas de este perfil (principal y auxiliares).
    func owns(_ window: NSWindow?) -> Bool
    func update(_ descriptor: ProfileDescriptor)
    func openWindow()
    func bringToFront()
    func teardown() async

    // Acciones de menú que el AppDelegate reenvía al perfil del frente.
    func showLoginWindow(_ sender: Any?)
    func signOut(_ sender: Any?)
    func refreshProfileExplorer(_ sender: Any?)
    func closeActiveSessionOrWindow(_ sender: Any?)
    func connectSelected(_ sender: Any?)
    func browseSelectedFiles(_ sender: Any?)
    func showSerialPortOutput(_ sender: Any?)
    func diagnoseSelected(_ sender: Any?)
    func showEventLog(_ sender: Any?)
}
