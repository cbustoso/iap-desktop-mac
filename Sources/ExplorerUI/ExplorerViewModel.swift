import Foundation

/// ViewModel del Explorer con la semántica de filtrado del original:
/// texto a nivel instancia (case-insensitive), toggles Linux/Windows
/// aplicados a nivel zona. Confinado al hilo principal (AppKit); la UI se
/// entera por `onChange`. Testeable sin UI (REQ-EXP-4).
public final class ExplorerViewModel {
    public var onChange: (() -> Void)?

    public var projects: [ProjectInfo] { didSet { onChange?() } }
    public var filterText: String = "" { didSet { onChange?() } }
    public var showLinux: Bool = true { didSet { onChange?() } }
    public var showWindows: Bool = true { didSet { onChange?() } }
    public var selection: InstanceInfo?

    public init(projects: [ProjectInfo] = []) {
        self.projects = projects
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

    private func osAllowed(_ os: GuestOS) -> Bool {
        switch os {
        case .linux: return showLinux
        case .windows: return showWindows
        }
    }
}
