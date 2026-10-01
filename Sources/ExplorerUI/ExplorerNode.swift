// ExplorerUI: nodo del árbol + presentación pura (icono, propiedades, menú
// contextual). Sin AppKit para que sea testeable sin ventana.

/// Nodo del árbol Google Cloud → Proyecto → Zona → Instancia.
public enum ExplorerNode: Hashable, Sendable {
    case cloud(projectCount: Int, instanceCount: Int)
    case project(ProjectInfo)
    case zone(ZoneInfo)
    case instance(InstanceInfo)

    /// Identidad estable entre recargas (el contenido filtrado cambia, el id no).
    public var id: String {
        switch self {
        case .cloud: return "cloud"
        case .project(let p): return "project:\(p.id)"
        case .zone(let z): return "zone:\(z.id)"
        case .instance(let i): return "instance:\(i.id)"
        }
    }

    public var title: String {
        switch self {
        case .cloud: return "Google Cloud"
        case .project(let p): return p.name
        case .zone(let z): return z.name
        case .instance(let i): return i.name
        }
    }

    /// SF Symbol por tipo de nodo (paridad con los iconos del IAP Desktop).
    public var symbolName: String {
        switch self {
        case .cloud: return "cloud"
        case .project: return "folder"
        case .zone: return "globe"
        case .instance(let i):
            switch i.os {
            case .linux: return "terminal"
            case .windows: return "pc"
            }
        }
    }

    /// Proyecto al que pertenece el nodo (para "Refresh project").
    public var projectName: String? {
        switch self {
        case .cloud: return nil
        case .project(let p): return p.name
        case .zone(let z): return z.project
        case .instance(let i): return i.project
        }
    }

    /// Filas del panel Properties. Nunca vacío para un nodo seleccionado.
    public var properties: [PropertyRow] {
        switch self {
        case .cloud(let projects, let instances):
            return [
                PropertyRow("Name", "Google Cloud"),
                PropertyRow("Type", "Cloud"),
                PropertyRow("Projects", "\(projects)"),
                PropertyRow("Instances", "\(instances)"),
            ]
        case .project(let p):
            let instances = p.zones.flatMap(\.instances)
            return [
                PropertyRow("Name", p.name),
                PropertyRow("Type", "Project"),
                PropertyRow("Zones", "\(p.zones.count)"),
                PropertyRow("Instances", "\(instances.count)"),
                PropertyRow("Running", "\(instances.filter { $0.status == .running }.count)"),
            ]
        case .zone(let z):
            return [
                PropertyRow("Name", z.name),
                PropertyRow("Type", "Zone"),
                PropertyRow("Project", z.project),
                PropertyRow("Instances", "\(z.instances.count)"),
                PropertyRow("Linux", "\(z.instances.filter { $0.os == .linux }.count)"),
                PropertyRow("Windows", "\(z.instances.filter { $0.os == .windows }.count)"),
            ]
        case .instance(let i):
            return [
                PropertyRow("Name", i.name),
                PropertyRow("Type", "VM instance"),
                PropertyRow("Project", i.project),
                PropertyRow("Zone", i.zone),
                PropertyRow("Operating system", i.os.displayName),
                PropertyRow("Status", i.status.displayName),
                PropertyRow("Session", i.connected ? "Connected" : "Not connected"),
                PropertyRow("Resource", "projects/\(i.project)/zones/\(i.zone)/instances/\(i.name)"),
            ]
        }
    }
}

public struct PropertyRow: Hashable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

extension GuestOS {
    public var displayName: String {
        switch self {
        case .linux: return "Linux"
        case .windows: return "Windows"
        }
    }

    /// Hito en el que llega la conexión para este SO.
    public var connectMilestone: String {
        switch self {
        case .linux: return "M1 (SSH)"
        case .windows: return "M2 (RDP)"
        }
    }
}

extension InstanceStatus {
    public var displayName: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Menú contextual

/// Comandos del menú contextual (subconjunto del IAP Desktop).
public enum ExplorerCommand: String, Sendable, CaseIterable {
    case connect
    case connectAsUser
    case connectionSettings
    /// Solo instancias Windows (paridad "Generate Windows logon credentials").
    case generateWindowsCredentials
    case refreshProject
    case properties

    public var title: String {
        switch self {
        case .connect: return "Connect"
        case .connectAsUser: return "Connect as user…"
        case .connectionSettings: return "Connection settings…"
        case .generateWindowsCredentials: return "Generate Windows credentials…"
        case .refreshProject: return "Refresh project"
        case .properties: return "Properties"
        }
    }

    public var symbolName: String {
        switch self {
        case .connect: return "play.display"
        case .connectAsUser: return "person.badge.key"
        case .connectionSettings: return "slider.horizontal.3"
        case .generateWindowsCredentials: return "key"
        case .refreshProject: return "arrow.clockwise"
        case .properties: return "info.circle"
        }
    }

    /// Hito en el que se implementa; `nil` = disponible ya.
    public var milestone: String? {
        switch self {
        case .connect: return "M1"
        case .connectAsUser, .connectionSettings: return "M2"
        case .generateWindowsCredentials, .refreshProject, .properties: return nil
        }
    }

    public var isAvailable: Bool { milestone == nil }
}

public enum ContextMenuEntry: Hashable, Sendable {
    case command(ExplorerCommand)
    case separator
}

public enum ExplorerContextMenu {
    public static func entries(for node: ExplorerNode) -> [ContextMenuEntry] {
        switch node {
        case .instance(let instance):
            let credentials: [ContextMenuEntry] = instance.os == .windows
                ? [.command(.generateWindowsCredentials)] : []
            return [.command(.connect), .command(.connectAsUser), .command(.connectionSettings)]
                + credentials + [
                .separator,
                .command(.refreshProject),
                .separator,
                .command(.properties),
            ]
        case .project, .zone:
            return [.command(.refreshProject), .separator, .command(.properties)]
        case .cloud:
            return [.command(.properties)]
        }
    }
}
