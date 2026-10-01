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

    public init(host: any SessionTabHosting) {
        self.host = host
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

        let view = TerminalSessionView(backend: backend)
        view.onEnded = { [weak self] in
            self?.host.setSessionTitle("\(title) — desconectado", identifier: instanceID)
            self?.onSessionEnded?(instanceID)
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
    public func close(instanceID: String) async {
        guard let view = views.removeValue(forKey: instanceID) else { return }
        titles[instanceID] = nil
        view.onEnded = nil
        host.closeSession(identifier: instanceID)
        await view.close()
        onSessionEnded?(instanceID)
    }

    public func closeAll() async {
        for id in Array(views.keys) { await close(instanceID: id) }
    }
}
