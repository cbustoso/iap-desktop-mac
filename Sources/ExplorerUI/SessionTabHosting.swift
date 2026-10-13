import AppKit

/// Área donde se acoplan sesiones como pestañas (el área central del Explorer).
/// ExplorerUI no conoce terminales ni SSH: TerminalUI (y en el futuro RDP)
/// abre aquí su vista con un identificador estable (el `id` de la instancia).
@MainActor
public protocol SessionTabHosting: AnyObject {
    /// Acopla `content` como pestaña y la activa; si ya existe una con ese
    /// identificador, solo la activa (una pestaña por instancia).
    func openSession(identifier: String, title: String, content: NSView)
    func closeSession(identifier: String)
    func setSessionTitle(_ title: String, identifier: String)
    var sessionIdentifiers: [String] { get }
    var selectedSessionIdentifier: String? { get }
    /// GH-64 (REQ-CLOSE-1): el usuario pulsó el `×` de la pestaña `identifier`.
    /// El área no cierra nada por sí misma: la App decide (confirmación, tipo
    /// de pestaña) y llama a `closeSession` si procede. `nil` = sin `×`.
    var onCloseRequested: (@MainActor (String) -> Void)? { get set }
}
