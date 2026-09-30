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

    public init(projects: [ProjectInfo] = []) {
        self.projects = projects
    }

    /// Replaces the current snapshot only after a complete successful load.
    /// On failure the existing data remains visible, preserving the mock
    /// fallback used before credentials are wired into the app.
    public func reloadFromGCP(
        workspace: ProjectWorkspace, projectIDs: [String]
    ) async {
        let selectedID = selection?.id
        do {
            let loadedProjects = try await workspace.reload(projectIDs: projectIDs)
            applyLoaded(loadedProjects, selectedID: selectedID)
        } catch {
            // Keep the last usable snapshot (including the initial mock data).
        }
    }

    /// Descubre todos los proyectos de la cuenta y los carga (flujo IAP:
    /// tras el login el árbol se llena solo).
    public func reloadAllFromGCP(workspace: ProjectWorkspace) async {
        let selectedID = selection?.id
        do {
            applyLoaded(try await workspace.reloadAll(), selectedID: selectedID)
        } catch {
            // Keep the last usable snapshot (including the initial mock data).
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

    /// Texto de la status bar: "LIVE — 2 proyectos, 6 instancias (3 visibles)".
    public func statusSummary(source _: String) -> String {
        let source = isLive ? "LIVE" : "MOCK"
        var text = "\(source) — \(Self.plural(projectCount, "proyecto", "proyectos")), "
            + Self.plural(instanceCount, "instancia", "instancias")
        let visible = visibleInstanceCount
        if visible != instanceCount {
            text += " (\(visible) \(visible == 1 ? "visible" : "visibles"))"
        }
        return text
    }

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
