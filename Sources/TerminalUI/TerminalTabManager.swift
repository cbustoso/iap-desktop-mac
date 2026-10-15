import AppKit
import ExplorerUI
import SSHKit

/// Pestañas de terminal en el área central del Explorer: **una por instancia**
/// (identificador = `InstanceInfo.id`), reutilizando `SessionTabHosting`.
@MainActor
public final class TerminalTabManager {
    private let host: any SessionTabHosting
    private var views: [String: TerminalSessionView] = [:]
    private var titles: [String: String] = [:]
    private var pendingShells: [String: Task<TerminalSessionView, any Error>] = [:]

    /// Una sesión terminó (exit remoto, caída) o se cerró su pestaña: la App
    /// libera aquí la conexión SSH de esa instancia.
    public var onSessionEnded: (@MainActor (String) -> Void)?

    /// GH-82: aspecto compartido por todas las pestañas, persistido en las
    /// claves de Settings (`TerminalFontFamily`/`TerminalFontSize`/`TerminalTheme`).
    public let appearanceStore: TerminalAppearanceStore
    public private(set) var appearance: TerminalAppearance

    public init(host: any SessionTabHosting, appearanceStore: TerminalAppearanceStore = TerminalAppearanceStore()) {
        self.host = host
        self.appearanceStore = appearanceStore
        appearance = appearanceStore.load()
    }

    /// Persiste `newAppearance` y lo aplica a todas las pestañas abiertas.
    public func setAppearance(_ newAppearance: TerminalAppearance) {
        appearanceStore.save(newAppearance)
        applyToOpenViews(newAppearance)
    }

    /// Vuelve a leer Settings (p. ej. tras guardar el panel) y lo aplica.
    public func reloadAppearance() {
        applyToOpenViews(appearanceStore.load())
    }

    private func applyToOpenViews(_ newAppearance: TerminalAppearance) {
        appearance = newAppearance
        for view in views.values where view.terminalAppearance != newAppearance {
            view.applyAppearance(newAppearance)
        }
    }

    /// Instancias con pestaña abierta (activa o desconectada).
    public var openInstanceIDs: [String] { host.sessionIdentifiers.filter { views[$0] != nil } }

    public func view(for instanceID: String) -> TerminalSessionView? { views[instanceID] }

    /// Abre (o reactiva) la pestaña de `instanceID` sobre `backend`.
    ///
    /// Si ya hay una pestaña viva para la instancia, se selecciona y se cierra
    /// el backend sobrante. Si la anterior terminó, se sustituye.
    @discardableResult
    public func open(instanceID: String, title: String, backend: any TerminalBackend) -> TerminalSessionView {
        if let existing = views[instanceID] {
            if !existing.hasEnded {
                host.openSession(identifier: instanceID, title: titles[instanceID] ?? title, content: existing)
                Task { await backend.close() }
                return existing
            }
            host.closeSession(identifier: instanceID)
            views[instanceID] = nil
        }

        // Settings pudo cambiar desde el panel: cada pestaña nueva lo relee.
        appearance = appearanceStore.load()
        let view = TerminalSessionView(backend: backend, appearance: appearance)
        view.onAppearanceChange = { [weak self] in self?.setAppearance($0) }
        view.onEnded = { [weak self, weak view] in
            self?.host.setSessionTitle("\(title) — desconectado", identifier: instanceID)
            if let view { self?.notifyEnded(instanceID, view: view) }
        }
        views[instanceID] = view
        titles[instanceID] = title
        host.openSession(identifier: instanceID, title: title, content: view)
        view.start()
        return view
    }

    /// Abre un shell sobre una sesión SSH ya autenticada y lo acopla como
    /// pestaña. Llamadas concurrentes para la misma instancia comparten el
    /// mismo shell (no se abren dos canales).
    public func openShell(instanceID: String, title: String, session: SshSession) async throws -> TerminalSessionView {
        if let existing = views[instanceID], !existing.hasEnded {
            host.openSession(identifier: instanceID, title: titles[instanceID] ?? title, content: existing)
            return existing
        }
        if let pending = pendingShells[instanceID] {
            return try await pending.value
        }
        let task = Task { @MainActor in
            defer { pendingShells[instanceID] = nil }
            let channel = try await session.openShell(terminal: SSHTerminalSize(columns: 80, rows: 24))
            return open(instanceID: instanceID, title: title, backend: channel)
        }
        pendingShells[instanceID] = task
        return try await task.value
    }

    /// Cierre limpio: cierra el canal remoto y quita la pestaña.
    /// Idempotente: una segunda llamada (o una carrera con el fin remoto) no
    /// hace nada ni repite `onSessionEnded`. La pestaña se quita antes de
    /// cerrar el canal, así que un fallo del canal no la deja en la UI.
    public func close(instanceID: String) async {
        guard let view = views.removeValue(forKey: instanceID) else { return }
        titles[instanceID] = nil
        view.onEnded = nil
        host.closeSession(identifier: instanceID)
        await view.close()
        notifyEnded(instanceID, view: view)
    }

    /// `onSessionEnded` como mucho una vez por pestaña (GH-64), aunque el
    /// remoto termine y luego se pulse `×`.
    private func notifyEnded(_ instanceID: String, view: TerminalSessionView) {
        guard !view.endNotified else { return }
        view.endNotified = true
        onSessionEnded?(instanceID)
    }

    public func closeAll() async {
        for id in Array(views.keys) { await close(instanceID: id) }
    }
}
