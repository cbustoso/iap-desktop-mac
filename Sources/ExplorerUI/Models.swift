// ExplorerUI (AppKit): modelos del árbol Cloud → Proyecto → Zona → Instancia.
// Paridad con ProjectWorkspace/InstanceNode (C#). Sin red: los datos los
// provee el llamador (mock en App, GCPClient en M1). Todo Sendable.
public enum GuestOS: String, Sendable, Hashable, CaseIterable {
    case linux
    case windows
}

public enum InstanceStatus: String, Sendable, Hashable {
    case running
    case stopped
    case unknown
}

public struct InstanceInfo: Sendable, Hashable, Identifiable {
    public var id: String { "\(project)/\(zone)/\(name)" }
    public var project: String
    public var zone: String
    public var name: String
    public var os: GuestOS
    public var status: InstanceStatus
    public var connected: Bool

    public init(
        project: String, zone: String, name: String,
        os: GuestOS, status: InstanceStatus, connected: Bool = false
    ) {
        self.project = project
        self.zone = zone
        self.name = name
        self.os = os
        self.status = status
        self.connected = connected
    }
}

public struct ZoneInfo: Sendable, Hashable, Identifiable {
    public var id: String { "\(project)/\(name)" }
    public var project: String
    public var name: String
    public var instances: [InstanceInfo]

    public init(project: String, name: String, instances: [InstanceInfo] = []) {
        self.project = project
        self.name = name
        self.instances = instances
    }
}

public struct ProjectInfo: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var zones: [ZoneInfo]

    public init(name: String, zones: [ZoneInfo] = []) {
        self.name = name
        self.zones = zones
    }
}
