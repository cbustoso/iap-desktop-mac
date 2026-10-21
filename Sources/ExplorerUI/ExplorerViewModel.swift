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
    private var azureSessionGeneration = 0
    private var azureDataSource: (any AzureExplorerDataSource)?
    public private(set) var azureState: AzureExplorerState?

    /// - Parameter isSignedIn: `false` en la App hasta restaurar/iniciar sesión;
    ///   `true` (default) para un snapshot ya autorizado (tests, previews).
    public init(
        projects: [ProjectInfo] = [], isSignedIn: Bool = true,
        azureAccount: AzureExplorerAccount? = nil,
        azureDataSource: (any AzureExplorerDataSource)? = nil
    ) {
        self.isSignedIn = isSignedIn
        self.projects = isSignedIn ? projects : []
        self.azureDataSource = azureDataSource
        if let azureAccount {
            azureState = azureDataSource == nil ? .noSession : .loading(azureAccount)
        }
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

    /// Installs the App-owned adapter after an Azure profile signs in.
    public func azureSessionStarted(
        account: AzureExplorerAccount, dataSource: any AzureExplorerDataSource
    ) {
        azureSessionGeneration += 1
        azureDataSource = dataSource
        azureState = .loading(account)
        onChange?()
    }

    /// Removes all Azure inventory while keeping an explicit no-session state.
    public func azureSessionEnded() {
        azureSessionGeneration += 1
        azureDataSource = nil
        azureState = .noSession
        onChange?()
    }

    /// Loads a complete, internally consistent Azure snapshot. Production data only comes
    /// from the App-provided adapter; ExplorerUI has no fallback or mock inventory.
    @discardableResult
    public func reloadAzure() async -> Result<Void, any Error> {
        guard let dataSource = azureDataSource else {
            azureState = .noSession
            onChange?()
            return .failure(ExplorerSessionError.signedOut)
        }
        let account: AzureExplorerAccount
        switch azureState {
        case .loading(let value), .failed(let value, _): account = value
        case .loaded(let snapshot): account = snapshot.account
        case .noSession, nil: return .failure(ExplorerSessionError.signedOut)
        }
        let generation = azureSessionGeneration
        azureState = .loading(account)
        onChange?()
        do {
            let snapshot = try await Self.loadAzure(account: account, dataSource: dataSource)
            guard generation == azureSessionGeneration else {
                return .failure(ExplorerSessionError.signedOut)
            }
            azureState = .loaded(snapshot)
            onChange?()
            return .success(())
        } catch {
            guard generation == azureSessionGeneration else {
                return .failure(ExplorerSessionError.signedOut)
            }
            azureState = .failed(account: account, message: Self.azureErrorMessage(error))
            onChange?()
            return .failure(error)
        }
    }

    @discardableResult
    public func selectAzureBastion(
        id: String?, forVirtualMachineID virtualMachineID: String
    ) async -> Result<Void, any Error> {
        guard let dataSource = azureDataSource else {
            return .failure(ExplorerSessionError.signedOut)
        }
        do {
            try await dataSource.selectBastion(id: id, forVirtualMachineID: virtualMachineID)
            guard case .loaded(let snapshot) = azureState else { return .success(()) }
            azureState = .loaded(Self.replacingBastionSelection(
                in: snapshot, virtualMachineID: virtualMachineID, selectedID: id))
            onChange?()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private static func loadAzure(
        account: AzureExplorerAccount, dataSource: any AzureExplorerDataSource
    ) async throws -> AzureExplorerSnapshot {
        var tenantNodes: [AzureExplorerTenantNode] = []
        for tenant in try await dataSource.listTenants() {
            var subscriptionNodes: [AzureExplorerSubscriptionNode] = []
            for subscription in try await dataSource.listSubscriptions(forTenantID: tenant.id) {
                var groupNodes: [AzureExplorerResourceGroupNode] = []
                let groups = try await dataSource.listResourceGroups(
                    forSubscriptionID: subscription.id, tenantID: tenant.id)
                for group in groups {
                    var vmNodes: [AzureExplorerVMNode] = []
                    let vms = try await dataSource.listVirtualMachines(
                        forResourceGroup: group.name, subscriptionID: subscription.id,
                        tenantID: tenant.id)
                    for vm in vms {
                        async let bastions = dataSource.listBastions(
                            forVirtualMachineID: vm.id, resourceGroup: group.name,
                            subscriptionID: subscription.id, tenantID: tenant.id)
                        async let powerState = dataSource.powerState(
                            forVirtualMachineID: vm.id, subscriptionID: subscription.id,
                            tenantID: tenant.id)
                        async let selectedID = dataSource.selectedBastionID(forVirtualMachineID: vm.id)
                        vmNodes.append(AzureExplorerVMNode(
                            tenant: tenant, subscription: subscription, resourceGroup: group,
                            virtualMachine: vm, powerState: try await powerState,
                            bastions: try await bastions, selectedBastionID: await selectedID))
                    }
                    groupNodes.append(AzureExplorerResourceGroupNode(
                        resourceGroup: group,
                        virtualMachines: vmNodes.sorted { $0.virtualMachine.name.localizedStandardCompare($1.virtualMachine.name) == .orderedAscending }))
                }
                subscriptionNodes.append(AzureExplorerSubscriptionNode(
                    subscription: subscription,
                    resourceGroups: groupNodes.sorted { $0.resourceGroup.name.localizedStandardCompare($1.resourceGroup.name) == .orderedAscending }))
            }
            tenantNodes.append(AzureExplorerTenantNode(
                tenant: tenant,
                subscriptions: subscriptionNodes.sorted { $0.subscription.displayName.localizedStandardCompare($1.subscription.displayName) == .orderedAscending }))
        }
        return AzureExplorerSnapshot(account: account, tenants: tenantNodes)
    }

    private static func replacingBastionSelection(
        in snapshot: AzureExplorerSnapshot, virtualMachineID: String, selectedID: String?
    ) -> AzureExplorerSnapshot {
        let tenants = snapshot.tenants.map { tenantNode in
            AzureExplorerTenantNode(tenant: tenantNode.tenant, subscriptions: tenantNode.subscriptions.map { subscriptionNode in
                AzureExplorerSubscriptionNode(subscription: subscriptionNode.subscription, resourceGroups: subscriptionNode.resourceGroups.map { groupNode in
                    AzureExplorerResourceGroupNode(resourceGroup: groupNode.resourceGroup, virtualMachines: groupNode.virtualMachines.map { vmNode in
                        guard vmNode.virtualMachine.id == virtualMachineID else { return vmNode }
                        return AzureExplorerVMNode(
                            tenant: vmNode.tenant, subscription: vmNode.subscription,
                            resourceGroup: vmNode.resourceGroup, virtualMachine: vmNode.virtualMachine,
                            powerState: vmNode.powerState, bastions: vmNode.bastions,
                            selectedBastionID: selectedID)
                    })
                })
            })
        }
        return AzureExplorerSnapshot(account: snapshot.account, tenants: tenants)
    }

    /// El adaptador puede traer su propia acción (`recoverySuggestion`: p. ej.
    /// pedir Reader en la suscripción); si no, la de la sesión `az`.
    private static func azureErrorMessage(_ error: any Error) -> String {
        let action = (error as? any LocalizedError)?.recoverySuggestion
            ?? "Instala Azure CLI y ejecuta `az login`, y vuelve a intentarlo."
        return "No se pudo cargar Azure: \(error.localizedDescription). \(action)"
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
        guard isSignedIn else {
            switch azureState {
            case .noSession, nil: return Self.signedOutSummary
            case .loading: return "Azure — Cargando…"
            case .failed: return "Azure — Error"
            case .loaded(let snapshot):
                let count = snapshot.tenants.reduce(0) { tenantTotal, tenant in
                    tenantTotal + tenant.subscriptions.reduce(0) { subscriptionTotal, subscription in
                        subscriptionTotal + subscription.resourceGroups.reduce(0) {
                            $0 + $1.virtualMachines.count
                        }
                    }
                }
                return "Azure — \(Self.plural(count, "máquina virtual", "máquinas virtuales"))"
            }
        }
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
