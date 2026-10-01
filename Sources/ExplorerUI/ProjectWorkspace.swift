import GCPClient

/// Loads immutable Explorer snapshots from Google Cloud.
public actor ProjectWorkspace {
    private let client: GCPClient

    public init(client: GCPClient) {
        self.client = client
    }

    /// Descubre todos los proyectos visibles y carga sus instancias.
    /// Equivale al "Add project" implícito del IAP original: tras el login,
    /// el árbol se llena solo, sin picker.
    public func reloadAll() async throws -> [ProjectInfo] {
        let projects = try await client.listProjects()
        return try await reload(projectIDs: projects.map(\.projectId))
    }

    /// Por qué falló el último discovery que cayó a los IDs conocidos
    /// (`nil` si el último descubrió). Antes se perdía en el fallback
    /// (CBU-47b): permite distinguir API apagada / scope / VPC-SC / IAM.
    public private(set) var lastDiscoveryFailure: GoogleAPIFailure?

    /// Como `reloadAll`, pero si listar falla con 403 (la cuenta no tiene
    /// `resourcemanager.projects.list` aunque sí acceso a proyectos
    /// concretos, o la API está apagada), carga los IDs conocidos en vez de
    /// fallar y guarda el motivo en `lastDiscoveryFailure`. Devuelve si se
    /// pudo descubrir. Cualquier otro error se propaga.
    public func reloadAllowingStored(stored: [String]) async throws -> (projects: [ProjectInfo], discovered: Bool) {
        do {
            let projects = try await reloadAll()
            lastDiscoveryFailure = nil
            return (projects, true)
        } catch let failure as GoogleAPIFailure where failure.status == 403 && !stored.isEmpty {
            lastDiscoveryFailure = failure
            return (try await reload(projectIDs: stored), false)
        }
    }

    /// Nota para la status bar cuando el discovery cayó a `shown` IDs
    /// añadidos a mano: una acción distinta por causa.
    public static func discoveryNote(for failure: GoogleAPIFailure?, shown: Int) -> String {
        let fallback = "mostrando \(shown) añadido(s)."
        switch failure?.cause {
        case .serviceDisabled:
            let target = failure?.activationURL?.absoluteString
                ?? "APIs & Services del proyecto del cliente OAuth"
            return "Cloud Resource Manager API no habilitada en el proyecto del cliente OAuth; \(fallback) Habilítala: \(target)"
        case .scopeInsufficient:
            return "El token no incluye el scope cloud-platform; \(fallback) Cierra sesión y vuelve a entrar aceptando el acceso a Google Cloud."
        case .vpcServiceControls:
            return "Listar proyectos está bloqueado por VPC Service Controls; \(fallback) Pide al admin acceso al perímetro."
        case .permissionDenied:
            return "Sin permiso para listar proyectos (403\(failure?.reason.map { " \($0)" } ?? "")); \(fallback) File → Add project… para añadir más."
        case .unauthenticated, .other, nil:
            return "No se pudieron listar proyectos (HTTP \(failure.map { String($0.status) } ?? "?")); \(fallback)"
        }
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
