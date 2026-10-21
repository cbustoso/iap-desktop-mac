import Foundation
@testable import ExplorerUI

actor MockAzureExplorerDataSource: AzureExplorerDataSource {
    enum Failure: Error, LocalizedError {
        case unavailable

        var errorDescription: String? { "ARM no disponible" }
    }

    var tenants: [AzureExplorerTenant]
    var subscriptions: [AzureExplorerSubscription]
    var resourceGroups: [AzureExplorerResourceGroup]
    var virtualMachines: [AzureExplorerVirtualMachine]
    var bastions: [AzureExplorerBastion]
    var powerStates: [String: AzureVMPowerState]
    var selections: [String: String]
    var failTenantListing = false

    init(
        tenants: [AzureExplorerTenant] = [],
        subscriptions: [AzureExplorerSubscription] = [],
        resourceGroups: [AzureExplorerResourceGroup] = [],
        virtualMachines: [AzureExplorerVirtualMachine] = [],
        bastions: [AzureExplorerBastion] = [],
        powerStates: [String: AzureVMPowerState] = [:],
        selections: [String: String] = [:]
    ) {
        self.tenants = tenants
        self.subscriptions = subscriptions
        self.resourceGroups = resourceGroups
        self.virtualMachines = virtualMachines
        self.bastions = bastions
        self.powerStates = powerStates
        self.selections = selections
    }

    func listTenants() async throws -> [AzureExplorerTenant] {
        if failTenantListing { throw Failure.unavailable }
        return tenants
    }

    func listSubscriptions(forTenantID tenantID: String) async throws -> [AzureExplorerSubscription] {
        subscriptions
    }

    func listResourceGroups(
        forSubscriptionID subscriptionID: String, tenantID: String
    ) async throws -> [AzureExplorerResourceGroup] {
        resourceGroups
    }

    func listVirtualMachines(
        forResourceGroup resourceGroup: String, subscriptionID: String, tenantID: String
    ) async throws -> [AzureExplorerVirtualMachine] {
        virtualMachines
    }

    func listBastions(
        forVirtualMachineID virtualMachineID: String, resourceGroup: String,
        subscriptionID: String, tenantID: String
    ) async throws -> [AzureExplorerBastion] {
        bastions
    }

    func powerState(
        forVirtualMachineID virtualMachineID: String, subscriptionID: String, tenantID: String
    ) async throws -> AzureVMPowerState? {
        powerStates[virtualMachineID]
    }

    func selectedBastionID(forVirtualMachineID virtualMachineID: String) async -> String? {
        selections[virtualMachineID]
    }

    func selectBastion(id: String?, forVirtualMachineID virtualMachineID: String) async throws {
        selections[virtualMachineID] = id
    }

    func setFailTenantListing(_ value: Bool) { failTenantListing = value }
}
