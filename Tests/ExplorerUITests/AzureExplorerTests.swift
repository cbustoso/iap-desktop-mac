import AppKit
import Testing
@testable import ExplorerUI

private let azureAccount = AzureExplorerAccount(
    id: "profile-azure", displayName: "Ada Azure", username: "ada@example.com")
private let azureTenant = AzureExplorerTenant(
    id: "tenant-1", displayName: "Contoso", defaultDomain: "contoso.example")
private let azureSubscription = AzureExplorerSubscription(
    id: "sub-1", displayName: "Production")
private let azureGroup = AzureExplorerResourceGroup(name: "compute-rg", location: "chilecentral")
private let azureVM = AzureExplorerVirtualMachine(
    id: "/subscriptions/sub-1/resourceGroups/compute-rg/providers/Microsoft.Compute/virtualMachines/web-01",
    name: "web-01", location: "chilecentral", operatingSystem: .linux,
    privateIPAddress: "10.0.0.4")
private let bastionA = AzureExplorerBastion(
    id: "/bastions/a", name: "bastion-a", sku: "Standard", enableTunneling: true)
private let bastionB = AzureExplorerBastion(
    id: "/bastions/b", name: "bastion-b", sku: "Premium", enableTunneling: true)

private func makeAzureDataSource(
    bastions: [AzureExplorerBastion] = [bastionA, bastionB], selected: String? = bastionA.id
) -> MockAzureExplorerDataSource {
    MockAzureExplorerDataSource(
        tenants: [azureTenant], subscriptions: [azureSubscription], resourceGroups: [azureGroup],
        virtualMachines: [azureVM], bastions: bastions,
        powerStates: [azureVM.id: .running], selections: selected.map { [azureVM.id: $0] } ?? [:])
}

@Suite("Azure Explorer (GH-92)")
@MainActor
struct AzureExplorerTests {
    @Test func loadsCompleteHierarchyAlongsideGoogleCloudAndShowsVMProperties() async throws {
        let dataSource = makeAzureDataSource()
        let viewModel = ExplorerViewModel(
            projects: [ProjectInfo(name: "gcp-project")], azureAccount: azureAccount,
            azureDataSource: dataSource)
        let controller = ExplorerWindowController(viewModel: viewModel, dataSourceLabel: "GCP")

        #expect(controller.selectNode(id: "cloud"))
        #expect(controller.selectNode(id: "azure"))
        #expect(controller.selectNode(id: "azure:status"))
        try await viewModel.reloadAzure().get()

        #expect(controller.selectNode(id: "azure:account:\(azureAccount.id)"))
        #expect(controller.selectNode(id: "azure:tenant:\(azureTenant.id)"))
        #expect(controller.selectNode(id: "azure:subscription:\(azureSubscription.id)"))
        #expect(controller.selectNode(id: "azure:resource-group:\(azureGroup.name)"))
        #expect(controller.selectNode(id: "azure:vm:\(azureVM.id)"))
        #expect(controller.selectedNode?.title == "web-01 — Running")

        let properties = Dictionary(uniqueKeysWithValues: controller.propertiesPane.rows.map { ($0.label, $0.value) })
        #expect(properties["Private IP"] == "10.0.0.4")
        #expect(properties["Resource group"] == "compute-rg")
        #expect(properties["Subscription"] == "Production")
        #expect(properties["Tenant"] == "Contoso")
        #expect(properties["Bastion"] == "bastion-a")
        #expect(properties["Power state"] == "Running")
    }

    @Test func bastionSelectorOffersEveryRealCandidateAndPersistsChoice() async throws {
        let dataSource = makeAzureDataSource(selected: nil)
        let viewModel = ExplorerViewModel(azureAccount: azureAccount, azureDataSource: dataSource)
        let controller = ExplorerWindowController(viewModel: viewModel)
        try await viewModel.reloadAzure().get()
        #expect(controller.selectNode(id: "azure:vm:\(azureVM.id)"))

        let selector = try #require(controller.propertiesPane.bastionSelector)
        #expect(selector.isEnabled)
        #expect(selector.numberOfItems == 3)
        #expect(selector.itemTitle(at: 0).contains("Sin asignar"))
        #expect(controller.selectedNode?.properties.first(where: { $0.label == "Connect" })?.value == "Selecciona un Bastion")

        try await viewModel.selectAzureBastion(id: bastionB.id, forVirtualMachineID: azureVM.id).get()
        #expect(await dataSource.selectedBastionID(forVirtualMachineID: azureVM.id) == bastionB.id)
        #expect(controller.selectedNode?.properties.first(where: { $0.label == "Bastion" })?.value == "bastion-b")
    }

    @Test func noBastionIsExplicitAndCannotInventASelection() async throws {
        let dataSource = makeAzureDataSource(bastions: [], selected: nil)
        let viewModel = ExplorerViewModel(azureAccount: azureAccount, azureDataSource: dataSource)
        let controller = ExplorerWindowController(viewModel: viewModel)
        try await viewModel.reloadAzure().get()
        #expect(controller.selectNode(id: "azure:vm:\(azureVM.id)"))

        let selector = try #require(controller.propertiesPane.bastionSelector)
        #expect(!selector.isEnabled)
        #expect(selector.titleOfSelectedItem == "No hay Bastion disponible")
        #expect(controller.selectedNode?.properties.first(where: { $0.label == "Connect" })?.value
            == "Sin Bastion disponible para esta VM")
    }

    @Test func loadingNoSessionAndActionableErrorStatesContainNoMockData() async {
        let dataSource = makeAzureDataSource()
        await dataSource.setFailTenantListing(true)
        let viewModel = ExplorerViewModel(azureAccount: azureAccount, azureDataSource: dataSource)
        let controller = ExplorerWindowController(viewModel: viewModel)

        #expect(controller.selectNode(id: "azure:status"))
        #expect(controller.selectedNode?.title == "Cargando…")
        if case .failure = await viewModel.reloadAzure() {} else { Issue.record("Expected load failure") }
        #expect(controller.selectNode(id: "azure:status"))
        let action = controller.selectedNode?.properties.first(where: { $0.label == "Action" })?.value
        #expect(action?.contains("Instala Azure CLI y ejecuta `az login`") == true)
        #expect(!controller.selectNode(id: "azure:tenant:\(azureTenant.id)"))

        viewModel.azureSessionEnded()
        #expect(controller.selectNode(id: "azure:status"))
        #expect(controller.selectedNode?.title == "Sin sesión Azure")
    }
}
