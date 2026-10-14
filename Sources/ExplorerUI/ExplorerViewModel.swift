import Foundation

/// ViewModel del Explorer con la semántica de filtrado del original:
/// texto a nivel instancia (case-insensitive), toggles Linux/Windows
/// aplicados a nivel zona. Confinado al hilo principal (AppKit); la UI se
/// entera por `onChange`. Testeable sin UI (REQ-EXP-4).
@MainActor
public final class ExplorerViewModel {
    public var onChange: (() -> Void)?

    public var projects: [ProjectInfo] { didSet { onChange?() } }
    public var filterText: String = "" { didSet { onChange?() } }
    public var showLinux: Bool = true { didSet { onChange?() } }
    public var showWindows: Bool = true { didSet { onChange?() } }
    public var selection: InstanceInfo?
    public private(set) var isLive = false
    /// GH-78: ¿hay sesión válida? Sin ella el Explorer no muestra nodos (ni
    /// mock): solo el estado vacío con "Sign In".
    public private(set) var isSignedIn: Bool
    /// Sube en cada fin de sesión: una carga empezada antes se descarta.
    private var sessionGeneration = 0

    /// - Parameter isSignedIn: `false` en la App hasta restaurar/iniciar sesión;
    ///   `true` (default) para un snapshot ya autorizado (tests, previews).
    public init(projects: [ProjectInfo] = [], isSignedIn: Bool = true) {
        self.isSignedIn = isSignedIn
        self.projects = isSignedIn ? projects : []
    }

    /// Sesión válida (restaurada o recién autorizada): habilita las cargas.
    public func sessionStarted() {
        guard !isSignedIn else { return }
        isSignedIn = true
        onChange?()
    }

    /// Logout o credenciales rechazadas (401): vacía el árbol y descarta las
    /// cargas en vuelo. La nota de la status bar la gestiona la App.
    public func sessionEnded() {
        sessionGeneration += 1
        selection = nil
        isLive = false
        isSignedIn = false
        projects = []
    }

    /// Replaces the current snapshot only after a complete successful load.
    /// On failure the existing data remains visible. Sin sesión no carga.
    public func reloadFromGCP(
        workspace: ProjectWorkspace, projectIDs: [String]
    ) async {
        guard isSignedIn else { return }
        let selectedID = selection?.id
        let generation = sessionGeneration
        do {
            let loadedProjects = try await workspace.reload(projectIDs: projectIDs)
            guard generation == sessionGeneration else { return }
            applyLoaded(loadedProjects, selectedID: selectedID)
        } catch {
            // Keep the last usable snapshot.
        }
    }

    /// Descubre todos los proyectos de la cuenta y los carga (flujo IAP:
    /// tras el login el árbol se llena solo).
    /// Devuelve el resultado para que la App lo registre y lo muestre
    /// (CBU-28d); ante un fallo se conserva el último snapshot.
    @discardableResult
    public func reloadAllFromGCP(workspace: ProjectWorkspace) async -> Result<Void, any Error> {
        switch await reloadAllowingStored(workspace: workspace, stored: []) {
        case .success: return .success(())
        case .failure(let error): return .failure(error)
        }
    }

    /// Como `reloadAllFromGCP` pero con fallback a IDs conocidos si listar
    /// falla con 403. Devuelve si se pudo descubrir (`true`) o se usaron los
    /// conocidos (`false`).
    public func reloadAllowingStored(
        workspace: ProjectWorkspace, stored: [String]
    ) async -> Result<Bool, any Error> {
        guard isSignedIn else { return .failure(ExplorerSessionError.signedOut) }
        let selectedID = selection?.id
        let generation = sessionGeneration
        do {
            let (loadedProjects, discovered) = try await workspace.reloadAllowingStored(stored: stored)
            // Logout/401 durante la carga: el resultado ya no vale.
            guard generation == sessionGeneration else { return .failure(ExplorerSessionError.signedOut) }
            applyLoaded(loadedProjects, selectedID: selectedID)
            return .success(discovered)
        } catch {
            return .failure(error)
        }
    }

    private func applyLoaded(_ loadedProjects: [ProjectInfo], selectedID: String?) {
        selection = selectedID.flatMap { id in
            loadedProjects.lazy
                .flatMap(\.zones)
                .flatMap(\.instances)
                .first { $0.id == id }
        }
        isLive = true
        projects = loadedProjects
    }

    /// Proyectos con zonas/instancias ya filtradas (estructura preservada).
    public var filteredProjects: [ProjectInfo] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.compactMap { project in
            let zones = project.zones.compactMap { zone -> ZoneInfo? in
                let instances = zone.instances.filter { instance in
                    osAllowed(instance.os)
                        && (query.isEmpty
                            || instance.name.localizedCaseInsensitiveContains(query))
                }
                guard !instances.isEmpty else { return nil }
                return ZoneInfo(project: zone.project, name: zone.name, instances: instances)
            }
            guard !zones.isEmpty else { return nil }
            return ProjectInfo(name: project.name, zones: zones)
        }
    }

    public var projectCount: Int { projects.count }
    public var instanceCount: Int { Self.instanceCount(in: projects) }
    public var visibleInstanceCount: Int { Self.instanceCount(in: filteredProjects) }

    /// Texto de la status bar: "LIVE — 2 proyectos, 6 instancias (3 visibles)";
    /// antes de la primera carga, `source`; sin sesión, "Sin sesión".
    public func statusSummary(source fallback: String) -> String {
        guard isSignedIn else { return Self.signedOutSummary }
        let source = isLive ? "LIVE" : fallback
        var text = "\(source) — \(Self.plural(projectCount, "proyecto", "proyectos")), "
            + Self.plural(instanceCount, "instancia", "instancias")
        let visible = visibleInstanceCount
        if visible != instanceCount {
            text += " (\(visible) \(visible == 1 ? "visible" : "visibles"))"
        }
        return text
    }

    public static let signedOutSummary = "Sin sesión"

    private static func instanceCount(in projects: [ProjectInfo]) -> Int {
        projects.reduce(0) { total, project in
            total + project.zones.reduce(0) { $0 + $1.instances.count }
        }
    }

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    private func osAllowed(_ os: GuestOS) -> Bool {
        switch os {
        case .linux: return showLinux
        case .windows: return showWindows
        }
    }
}

/// GH-78: carga pedida (o terminada) sin sesión válida.
public enum ExplorerSessionError: Error, Equatable, Sendable {
    case signedOut
}
