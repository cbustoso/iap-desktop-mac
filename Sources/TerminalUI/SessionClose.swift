// GH-64 (specs/ssh-close): cierre individual de pestañas SSH con confirmación
// solo si hay actividad, y cierre agregado de la ventana (un único diálogo).
// La heurística es APROXIMADA: SSH remoto no expone la tabla de procesos; se
// usa lo observable desde el cliente y se prefiere preguntar de más.
import AppKit
import ExplorerUI
import Foundation
import OSLog

/// ¿Hay "proceso activo" en la sesión de una pestaña? (REQ-CLOSE-3)
@MainActor
public struct SessionCloseConfirmer {
    /// Transferencia SFTP en curso sobre la misma sesión (pestaña Files).
    public var hasActiveTransfer: @MainActor (String) -> Bool
    /// Salida remota reciente; `nil` = no evaluable (→ no se pregunta).
    public var recentOutputWithinWindow: @MainActor (String) -> Bool?

    public init(
        hasActiveTransfer: @escaping @MainActor (String) -> Bool,
        recentOutputWithinWindow: @escaping @MainActor (String) -> Bool?
    ) {
        self.hasActiveTransfer = hasActiveTransfer
        self.recentOutputWithinWindow = recentOutputWithinWindow
    }

    public func isActive(instanceID: String) -> Bool {
        hasActiveTransfer(instanceID) || (recentOutputWithinWindow(instanceID) ?? false)
    }

    /// Confirmador de producción sobre las pestañas de `tabs`.
    public static func live(
        tabs: TerminalTabManager, window: TimeInterval = 2, now: @escaping @MainActor () -> Date = { Date() },
        hasActiveTransfer: @escaping @MainActor (String) -> Bool
    ) -> SessionCloseConfirmer {
        SessionCloseConfirmer(hasActiveTransfer: hasActiveTransfer) { [weak tabs] instanceID in
            guard let view = tabs?.view(for: instanceID) else { return nil }
            if view.hasEnded { return false }  // canal cerrado: nada corre
            return recentOutput(
                lastOutputAt: view.lastOutputAt, lastEmptyEnterAt: view.lastEmptyEnterAt, now: now(), window: window)
        }
    }

    /// REQ-CLOSE-3.2: salida en los últimos `window` segundos, salvo que sea la
    /// respuesta a un Enter sobre línea vacía (el prompt). Sin salida nunca → no activa.
    public static func recentOutput(lastOutputAt: Date?, lastEmptyEnterAt: Date?, now: Date, window: TimeInterval) -> Bool {
        guard let lastOutputAt, now.timeIntervalSince(lastOutputAt) <= window else { return false }
        if let enter = lastEmptyEnterAt, enter <= lastOutputAt, lastOutputAt.timeIntervalSince(enter) <= window {
            return false
        }
        return true
    }
}

/// Orquesta `×`/`⌘W`/cierre de ventana → confirmación → `TerminalTabManager.close`.
/// Nunca muestra más de un diálogo por pestaña ni más de uno por cierre de ventana.
@MainActor
public final class SessionCloseCoordinator {
    /// Pregunta (mensaje, detalle, botón de confirmar) → `true` si confirma.
    public typealias Ask = @MainActor (_ message: String, _ informative: String, _ confirm: String) async -> Bool

    static let log = Logger(subsystem: "com.iapdesktop.mac", category: "ssh")

    private let tabs: TerminalTabManager
    private let host: any SessionTabHosting
    private let confirmer: SessionCloseConfirmer
    private let ask: Ask
    private var asking: Set<String> = []
    private var windowConfirmationPending = false
    private var windowCloseApproved = false

    public init(tabs: TerminalTabManager, host: any SessionTabHosting, confirmer: SessionCloseConfirmer, ask: @escaping Ask) {
        self.tabs = tabs
        self.host = host
        self.confirmer = confirmer
        self.ask = ask
    }

    public func isSessionTab(_ identifier: String) -> Bool {
        tabs.openInstanceIDs.contains(identifier)
    }

    /// `×` o `⌘W` sobre una pestaña SSH. `true` si se cerró.
    @discardableResult
    public func requestClose(instanceID: String, title: String) async -> Bool {
        guard isSessionTab(instanceID), !asking.contains(instanceID) else { return false }
        Self.log.notice("session-close requested instance=\(instanceID, privacy: .public)")
        if confirmer.isActive(instanceID: instanceID) {
            asking.insert(instanceID)
            let confirmed = await ask(
                "¿Cerrar \(title)?", "Hay actividad en curso en esta sesión.", "Close")
            asking.remove(instanceID)
            guard confirmed else {
                Self.log.notice("session-close cancelled instance=\(instanceID, privacy: .public)")
                return false
            }
        }
        Self.log.notice("session-close confirmed instance=\(instanceID, privacy: .public)")
        await tabs.close(instanceID: instanceID)
        return true
    }

    /// `⌘W` contextual (REQ-CLOSE-2): pestaña SSH seleccionada → solo esa;
    /// si no, `closeWindow()` (comportamiento anterior).
    public func closeActiveSessionOrWindow(title: (String) -> String, closeWindow: () -> Void) {
        if let selected = host.selectedSessionIdentifier, isSessionTab(selected) {
            let name = title(selected)
            Task { await requestClose(instanceID: selected, title: name) }
        } else {
            closeWindow()
        }
    }

    /// `windowShouldClose` (REQ-CLOSE-5). Sin pestañas → `true`. Si hay, devuelve
    /// `false`, pregunta UNA vez si alguna está activa, cierra todo (`closeOthers`
    /// para Files + todas las SSH) y llama a `reclose()`; ese segundo intento
    /// devuelve `true`. Cancelar deja ventana y pestañas intactas.
    public func windowShouldClose(hasOtherTabs: Bool, closeOthers: @escaping @MainActor () -> Void, reclose: @escaping @MainActor () -> Void) -> Bool {
        if windowCloseApproved { return true }
        let open = tabs.openInstanceIDs
        guard !open.isEmpty || hasOtherTabs else { return true }
        guard !windowConfirmationPending else { return false }
        let active = open.filter { confirmer.isActive(instanceID: $0) }
        windowConfirmationPending = true
        Task { @MainActor in
            defer { windowConfirmationPending = false }
            if !active.isEmpty {
                let informative = active.count == 1
                    ? "Hay 1 sesión con actividad. Se cerrarán \(open.count) sesión(es) SSH."
                    : "Hay \(active.count) sesiones con actividad. Se cerrarán \(open.count) sesiones SSH."
                guard await ask("¿Cerrar la ventana?", informative, "Close") else {
                    Self.log.notice("session-close cancelled scope=window")
                    return
                }
            }
            Self.log.notice("session-close confirmed scope=window sessions=\(open.count, privacy: .public)")
            closeOthers()
            await tabs.closeAll()
            windowCloseApproved = true
            reclose()
        }
        return false
    }

    /// Diálogo por defecto: hoja sobre `window` si es visible; modal si no.
    public static func alertAsk(window: @escaping @MainActor () -> NSWindow?) -> Ask {
        { message, informative, confirm in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = message
            alert.informativeText = informative
            alert.addButton(withTitle: confirm)
            alert.addButton(withTitle: "Cancel")
            if let window = window(), window.isVisible {
                return await withCheckedContinuation { continuation in
                    alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
                }
            }
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}
