// GH-90 (specs/azure/azure-bastion-research.md §2, §9.2): árbol del Explorer
// para Azure. tenants → suscripciones → resource groups → VMs, y para cada VM
// su NIC (IP privada, VNet) y el Bastion candidato de esa misma VNet. Los
// fallos son por nodo: un tenant sin consentimiento o una suscripción sin
// Reader no tiran el resto del árbol.
import Foundation

/// Por qué una VM no tiene Bastion asociado (A1.6: siempre hay un motivo).
public enum BastionAssociation: Sendable, Equatable {
    case sameVirtualNetwork(AzureBastion)
    /// La VM no declara NIC.
    case noNetworkInterface
    /// La NIC no se pudo leer (falta Reader sobre la NIC o falló el listado).
    case networkInterfaceNotVisible
    /// No se pudieron listar los Bastion de la suscripción.
    case bastionsNotVisible
    /// Ningún Bastion en la VNet de la VM. Puede haber uno en una VNet
    /// peered: F1 no lee peerings, el usuario lo elegirá a mano (§2).
    case noBastionInVirtualNetwork(virtualNetworkID: String)
}

public struct AzureVMNode: Sendable, Equatable {
    public let vm: AzureVM
    public let networkInterface: AzureNIC?
    public let bastion: BastionAssociation

    public var privateIPAddress: String? { networkInterface?.primaryConfiguration?.privateIPAddress }
    public var virtualNetworkID: String? { networkInterface?.virtualNetworkID }
}

public struct AzureResourceGroupNode: Sendable, Equatable {
    public let name: String
    public let location: String?
    public let virtualMachines: [AzureVMNode]
}

public struct AzureSubscriptionNode: Sendable {
    public let subscription: AzureSubscription
    /// Tenant cuyo token da acceso (el del listado; con Lighthouse no
    /// coincide con `subscription.tenantID`).
    public let accessTenantID: String
    public let resourceGroups: [AzureResourceGroupNode]
    public let failure: (any Error)?
}

public struct AzureTenantNode: Sendable {
    public let tenant: AzureTenant
    public let subscriptions: [AzureSubscriptionNode]
    /// Sin token para el tenant (consentimiento, MFA, CA) o sin listado.
    public let failure: (any Error)?
}

public struct AzureInventory: Sendable {
    public let tenants: [AzureTenantNode]
    /// `GET /tenants` falló: el árbol tiene solo el tenant de origen.
    public let tenantListFailure: (any Error)?
}

public struct AzureDiscovery: Sendable {
    private let client: AzureARMClient
    private let maxConcurrentSubscriptions: Int

    public init(client: AzureARMClient, maxConcurrentSubscriptions: Int = 4) {
        self.client = client
        self.maxConcurrentSubscriptions = max(1, maxConcurrentSubscriptions)
    }

    public func discover(homeTenantID: String) async -> AzureInventory {
        var tenantListFailure: (any Error)?
        var tenants: [AzureTenant]
        do {
            tenants = try await client.tenants(homeTenantID: homeTenantID)
        } catch {
            tenantListFailure = error
            tenants = []
        }
        if !tenants.contains(where: { $0.tenantID.caseInsensitiveCompare(homeTenantID) == .orderedSame }) {
            tenants.insert(AzureTenant(tenantID: homeTenantID, tenantCategory: "Home"), at: 0)
        }

        // 1. Suscripciones por tenant (cada una con el token de su tenant).
        var listed: [(tenant: AzureTenant, subscriptions: [AzureSubscription], failure: (any Error)?)] = []
        await withTaskGroup(of: (Int, [AzureSubscription], (any Error)?).self) { group in
            for (index, tenant) in tenants.enumerated() {
                group.addTask {
                    do {
                        return (index, try await client.subscriptions(tenantID: tenant.tenantID), nil)
                    } catch {
                        return (index, [], error)
                    }
                }
            }
            var results = [(Int, [AzureSubscription], (any Error)?)]()
            for await result in group { results.append(result) }
            listed = results.sorted { $0.0 < $1.0 }.map { (tenants[$0.0], $0.1, $0.2) }
        }

        // 2. Una suscripción visible desde varios tenants (Lighthouse) se
        //    carga una vez: con el tenant dueño si está, si no con el primero.
        var owner: [String: (tenantIndex: Int, subscription: AzureSubscription)] = [:]
        for (tenantIndex, entry) in listed.enumerated() {
            for subscription in entry.subscriptions where subscription.isUsable {
                let key = subscription.subscriptionID.lowercased()
                let ownsIt = subscription.tenantID?.caseInsensitiveCompare(entry.tenant.tenantID) == .orderedSame
                if owner[key] == nil || ownsIt { owner[key] = (tenantIndex, subscription) }
            }
        }

        // 3. Contenido de cada suscripción, como mucho N a la vez.
        let jobs = owner.values.sorted { ($0.tenantIndex, $0.subscription.displayName) < ($1.tenantIndex, $1.subscription.displayName) }
        var loaded: [String: AzureSubscriptionNode] = [:]
        await withTaskGroup(of: AzureSubscriptionNode.self) { group in
            var pending = jobs[...]
            func enqueue() {
                guard let job = pending.popFirst() else { return }
                let accessTenant = listed[job.tenantIndex].tenant.tenantID
                group.addTask { await load(job.subscription, accessTenantID: accessTenant) }
            }
            for _ in 0..<maxConcurrentSubscriptions { enqueue() }
            for await node in group {
                loaded[node.subscription.subscriptionID.lowercased()] = node
                enqueue()
            }
        }

        let nodes = listed.enumerated().map { tenantIndex, entry in
            let subscriptions = owner.values
                .filter { $0.tenantIndex == tenantIndex }
                .compactMap { loaded[$0.subscription.subscriptionID.lowercased()] }
                .sorted { $0.subscription.displayName.localizedStandardCompare($1.subscription.displayName) == .orderedAscending }
            return AzureTenantNode(tenant: entry.tenant, subscriptions: subscriptions, failure: entry.failure)
        }
        return AzureInventory(tenants: nodes, tenantListFailure: tenantListFailure)
    }

    /// RGs + VMs son imprescindibles; NICs y Bastions degradan por VM.
    func load(_ subscription: AzureSubscription, accessTenantID tenant: String) async -> AzureSubscriptionNode {
        let id = subscription.subscriptionID
        async let groups = client.resourceGroups(subscriptionID: id, tenantID: tenant)
        async let vms = client.virtualMachines(subscriptionID: id, tenantID: tenant)
        async let nics = Self.attempt { try await client.networkInterfaces(subscriptionID: id, tenantID: tenant) }
        async let bastions = Self.attempt { try await client.bastionHosts(subscriptionID: id, tenantID: tenant) }
        do {
            let tree = Self.assemble(
                groups: try await groups, vms: try await vms, nics: await nics, bastions: await bastions)
            return AzureSubscriptionNode(subscription: subscription, accessTenantID: tenant, resourceGroups: tree, failure: nil)
        } catch {
            return AzureSubscriptionNode(subscription: subscription, accessTenantID: tenant, resourceGroups: [], failure: error)
        }
    }

    private static func attempt<T: Sendable>(_ body: () async throws -> T) async -> T? {
        try? await body()
    }

    /// Agrupa VMs por resource group y empareja cada una con su Bastion.
    static func assemble(groups: [AzureResourceGroup], vms: [AzureVM], nics: [AzureNIC]?, bastions: [AzureBastion]?) -> [AzureResourceGroupNode] {
        let nicByID = Dictionary((nics ?? []).map { (ARMResourceID.normalized($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        var bastionByVNet: [String: AzureBastion] = [:]
        for bastion in (bastions ?? []).sorted(by: { ($0.supportsNativeClient ? 0 : 1, $0.name) < ($1.supportsNativeClient ? 0 : 1, $1.name) }) {
            for vnet in bastion.virtualNetworkIDs where bastionByVNet[ARMResourceID.normalized(vnet)] == nil {
                bastionByVNet[ARMResourceID.normalized(vnet)] = bastion  // preferido: el que soporta native client
            }
        }

        func node(for vm: AzureVM) -> AzureVMNode {
            guard let nicID = vm.primaryNetworkInterfaceID else { return AzureVMNode(vm: vm, networkInterface: nil, bastion: .noNetworkInterface) }
            guard let nic = nicByID[ARMResourceID.normalized(nicID)], let vnet = nic.virtualNetworkID else {
                return AzureVMNode(vm: vm, networkInterface: nil, bastion: .networkInterfaceNotVisible)
            }
            guard bastions != nil else { return AzureVMNode(vm: vm, networkInterface: nic, bastion: .bastionsNotVisible) }
            guard let bastion = bastionByVNet[ARMResourceID.normalized(vnet)] else {
                return AzureVMNode(vm: vm, networkInterface: nic, bastion: .noBastionInVirtualNetwork(virtualNetworkID: vnet))
            }
            return AzureVMNode(vm: vm, networkInterface: nic, bastion: .sameVirtualNetwork(bastion))
        }

        var vmsByGroup: [String: [AzureVMNode]] = [:]
        for vm in vms {
            vmsByGroup[(vm.resourceGroup ?? "").lowercased(), default: []].append(node(for: vm))
        }
        var result = groups.map { group in
            AzureResourceGroupNode(
                name: group.name, location: group.location,
                virtualMachines: (vmsByGroup.removeValue(forKey: group.name.lowercased()) ?? []).sorted { $0.vm.name < $1.vm.name })
        }
        // VMs de un RG que el listado no trajo (creado entre llamadas): no se pierden.
        for (key, nodes) in vmsByGroup {
            result.append(AzureResourceGroupNode(name: nodes.first?.vm.resourceGroup ?? key, location: nil, virtualMachines: nodes.sorted { $0.vm.name < $1.vm.name }))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
