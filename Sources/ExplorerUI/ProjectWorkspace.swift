import GCPClient

/// Loads immutable Explorer snapshots from Google Cloud.
public actor ProjectWorkspace {
    private let client: GCPClient

    public init(client: GCPClient) {
        self.client = client
    }

    /// Loads every configured project concurrently. GCPClient turns 403/404
    /// responses into an empty instance list, so inaccessible projects remain
    /// in the snapshot with no zones instead of failing the whole reload.
    public func reload(projectIDs: [String]) async throws -> [ProjectInfo] {
        try await withThrowingTaskGroup(of: (Int, ProjectInfo).self) { group in
            for (index, projectID) in projectIDs.enumerated() {
                group.addTask { [client] in
                    let instances = try await client.aggregatedListInstances(project: projectID)
                    return (index, Self.projectInfo(projectID: projectID, instances: instances))
                }
            }

            var loaded: [(Int, ProjectInfo)] = []
            for try await project in group {
                loaded.append(project)
            }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func projectInfo(
        projectID: String, instances: [ComputeInstance]
    ) -> ProjectInfo {
        let usableInstances = instances.filter { $0.disks != nil }
        let instancesByZone = Dictionary(grouping: usableInstances, by: \.zone)
        let zones = instancesByZone.keys.sorted().map { zoneName in
            let mappedInstances = (instancesByZone[zoneName] ?? [])
                .map { instance in
                    InstanceInfo(
                        project: projectID,
                        zone: zoneName,
                        name: instance.name,
                        os: Self.guestOS(instance.operatingSystem),
                        status: Self.instanceStatus(instance.status))
                }
                .sorted { $0.name < $1.name }
            return ZoneInfo(project: projectID, name: zoneName, instances: mappedInstances)
        }
        return ProjectInfo(name: projectID, zones: zones)
    }

    private static func guestOS(_ operatingSystem: OperatingSystem) -> GuestOS {
        switch operatingSystem {
        case .linux: return .linux
        case .windows: return .windows
        }
    }

    private static func instanceStatus(_ powerState: InstancePowerState) -> InstanceStatus {
        switch powerState {
        case .running: return .running
        case .stopped: return .stopped
        case .unknown: return .unknown
        }
    }
}
