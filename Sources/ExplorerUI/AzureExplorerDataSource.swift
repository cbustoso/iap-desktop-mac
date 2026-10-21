import Foundation

/// Integration seam between ExplorerUI and an Azure profile session.
///
/// ExplorerUI deliberately owns this protocol and its presentation DTOs. The App target
/// adapts `AzureDiscovery`, credentials and profile-scoped settings to it; ExplorerUI never
/// invokes Azure CLI or ARM directly. Implementations must keep Bastion selection isolated
/// per profile and persist `selectBastion` choices by VM ID when appropriate.
public protocol AzureExplorerDataSource: Sendable {
    func listTenants() async throws -> [AzureExplorerTenant]
    func listSubscriptions(forTenantID tenantID: String) async throws -> [AzureExplorerSubscription]
    func listResourceGroups(
        forSubscriptionID subscriptionID: String, tenantID: String
    ) async throws -> [AzureExplorerResourceGroup]
    func listVirtualMachines(
        forResourceGroup resourceGroup: String, subscriptionID: String, tenantID: String
    ) async throws -> [AzureExplorerVirtualMachine]
    func listBastions(
        forVirtualMachineID virtualMachineID: String, resourceGroup: String,
        subscriptionID: String, tenantID: String
    ) async throws -> [AzureExplorerBastion]
    func powerState(
        forVirtualMachineID virtualMachineID: String, subscriptionID: String, tenantID: String
    ) async throws -> AzureVMPowerState?
    func selectedBastionID(forVirtualMachineID virtualMachineID: String) async -> String?
    func selectBastion(id: String?, forVirtualMachineID virtualMachineID: String) async throws
}

public struct AzureExplorerAccount: Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let username: String?

    public init(id: String, displayName: String, username: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.username = username
    }
}

public struct AzureExplorerTenant: Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String?
    public let defaultDomain: String?

    public init(id: String, displayName: String? = nil, defaultDomain: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.defaultDomain = defaultDomain
    }
}

public struct AzureExplorerSubscription: Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let state: String

    public init(id: String, displayName: String, state: String = "Enabled") {
        self.id = id
        self.displayName = displayName
        self.state = state
    }
}

public struct AzureExplorerResourceGroup: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let location: String?

    public init(name: String, location: String? = nil) {
        self.name = name
        self.location = location
    }
}

public enum AzureVMPowerState: Hashable, Sendable {
    case running
    case starting
    case stopping
    case stopped
    case deallocated
    case unknown(String)

    public var displayName: String {
        switch self {
        case .running: "Running"
        case .starting: "Starting"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .deallocated: "Deallocated"
        case .unknown(let value): value.isEmpty ? "Unknown" : value
        }
    }
}

public struct AzureExplorerVirtualMachine: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let location: String
    public let operatingSystem: GuestOS?
    public let privateIPAddress: String?

    public init(
        id: String, name: String, location: String, operatingSystem: GuestOS? = nil,
        privateIPAddress: String? = nil
    ) {
        self.id = id
        self.name = name
        self.location = location
        self.operatingSystem = operatingSystem
        self.privateIPAddress = privateIPAddress
    }
}

public struct AzureExplorerBastion: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let sku: String
    public let enableTunneling: Bool

    public init(id: String, name: String, sku: String, enableTunneling: Bool) {
        self.id = id
        self.name = name
        self.sku = sku
        self.enableTunneling = enableTunneling
    }

    public var supportsNativeClient: Bool {
        ["standard", "premium"].contains(sku.lowercased()) && enableTunneling
    }
}

public struct AzureExplorerVMNode: Hashable, Sendable {
    public let tenant: AzureExplorerTenant
    public let subscription: AzureExplorerSubscription
    public let resourceGroup: AzureExplorerResourceGroup
    public let virtualMachine: AzureExplorerVirtualMachine
    public let powerState: AzureVMPowerState?
    public let bastions: [AzureExplorerBastion]
    public let selectedBastionID: String?

    public var selectedBastion: AzureExplorerBastion? {
        selectedBastionID.flatMap { id in bastions.first { $0.id == id } }
    }

    public var connectDisabledReason: String? {
        guard let bastion = selectedBastion else {
            return bastions.isEmpty ? "Sin Bastion disponible para esta VM" : "Selecciona un Bastion"
        }
        guard ["standard", "premium"].contains(bastion.sku.lowercased()) else {
            return "SKU \(bastion.sku) sin Native Client"
        }
        return bastion.enableTunneling ? nil : "Native Client deshabilitado en \(bastion.name)"
    }
}

public struct AzureExplorerResourceGroupNode: Hashable, Sendable {
    public let resourceGroup: AzureExplorerResourceGroup
    public let virtualMachines: [AzureExplorerVMNode]
}

public struct AzureExplorerSubscriptionNode: Hashable, Sendable {
    public let subscription: AzureExplorerSubscription
    public let resourceGroups: [AzureExplorerResourceGroupNode]
}

public struct AzureExplorerTenantNode: Hashable, Sendable {
    public let tenant: AzureExplorerTenant
    public let subscriptions: [AzureExplorerSubscriptionNode]
}

public struct AzureExplorerSnapshot: Hashable, Sendable {
    public let account: AzureExplorerAccount
    public let tenants: [AzureExplorerTenantNode]
}

public enum AzureExplorerState: Hashable, Sendable {
    case noSession
    case loading(AzureExplorerAccount)
    case loaded(AzureExplorerSnapshot)
    case failed(account: AzureExplorerAccount, message: String)
}
