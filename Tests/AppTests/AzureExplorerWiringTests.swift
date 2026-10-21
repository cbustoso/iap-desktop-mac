import AppKit
import AuthKit
import AzureClient
import Foundation
import Testing
@testable import App
@testable import ExplorerUI

// GH-98: `AzureExplorerDataSourceLive` sobre ARM falso (`ARMStub`, sin red) y
// su cableado en `AzureProfileSession`: tenant → suscripción → RG → VM →
// Bastion en el Explorer, con power state y selector de Bastion reales.

/// IDs con formato UUID (ARM valida el de la suscripción antes de pedir).
private let prod = "0b000000-0000-0000-0000-00000000000b"
private let dev = "0a000000-0000-0000-0000-00000000000a"
private let vmID = "/subscriptions/\(prod)/resourceGroups/compute-rg/providers/Microsoft.Compute/virtualMachines/web-01"
private let nicID = "/subscriptions/\(prod)/resourceGroups/compute-rg/providers/Microsoft.Network/networkInterfaces/web-01-nic"
private let hubVNet = "/subscriptions/\(prod)/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/hub"
private let spokeVNet = "/subscriptions/\(prod)/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/spoke"
private let hubBastion = "/subscriptions/\(prod)/resourceGroups/net-rg/providers/Microsoft.Network/bastionHosts/hub-bastion"
/// Otra VNet (p. ej. peered): candidato manual, nunca autoasignado.
private let spokeBastion = "/subscriptions/\(prod)/resourceGroups/net-rg/providers/Microsoft.Network/bastionHosts/aaa-bastion"

private let prodAccounts = "[\(account(dev, tenant: home, name: "Dev")),\(account(prod, tenant: home, name: "Prod", isDefault: true))]"

private func bastionJSON(_ id: String, name: String, sku: String, vnet: String) -> String {
    """
    {"id":"\(id)","name":"\(name)","location":"chilecentral","sku":{"name":"\(sku)"},\
    "properties":{"dnsName":"bst-\(name).bastion.azure.com","enableTunneling":true,\
    "ipConfigurations":[{"properties":{"subnet":{"id":"\(vnet)/subnets/AzureBastionSubnet"}}}]}}
    """
}

/// ARM con un tenant (Contoso), dos suscripciones y el inventario de Prod:
/// compute-rg (web-01, Linux, running) y net-rg (sin VMs), dos Bastion. Dev, vacía.
private func inventoryARM(groupsStatus: Int = 200) -> (URLSession, @Sendable () -> [ARMStub.Request]) {
    ARMStub.session { request in
        let path = request.path
        let sub = "/subscriptions/\(prod)"
        if path.hasPrefix("/subscriptions/\(dev)/") { return (200, page([])) }
        switch path {
        case "/tenants":
            return (200, page([#"{"tenantId":"\#(home)","displayName":"Contoso","defaultDomain":"contoso.com"}"#]))
        case "/subscriptions":
            return (200, page([
                #"{"subscriptionId":"\#(prod)","tenantId":"\#(home)","displayName":"Prod","state":"Enabled"}"#,
                #"{"subscriptionId":"\#(dev)","tenantId":"\#(home)","displayName":"Dev","state":"Enabled"}"#,
            ]))
        case "\(sub)/resourcegroups":
            guard groupsStatus == 200 else {
                return (groupsStatus, #"{"error":{"code":"AuthorizationFailed","message":"The client does not have authorization"}}"#)
            }
            return (200, page([
                #"{"id":"\#(sub)/resourceGroups/compute-rg","name":"compute-rg","location":"chilecentral"}"#,
                #"{"id":"\#(sub)/resourceGroups/net-rg","name":"net-rg","location":"chilecentral"}"#,
            ]))
        case "\(sub)/providers/Microsoft.Compute/virtualMachines" where request.query?.contains("statusOnly=true") == true:
            return (200, page([
                #"{"id":"\#(vmID)","name":"web-01","properties":{"instanceView":{"statuses":[{"code":"ProvisioningState/succeeded"},{"code":"PowerState/running"}]}}}"#,
            ]))
        case "\(sub)/providers/Microsoft.Compute/virtualMachines":
            return (200, page([
                #"{"id":"\#(vmID)","name":"web-01","location":"chilecentral","properties":{"storageProfile":{"osDisk":{"osType":"Linux"}},"networkProfile":{"networkInterfaces":[{"id":"\#(nicID)","properties":{"primary":true}}]}}}"#,
            ]))
        case "\(sub)/providers/Microsoft.Network/networkInterfaces":
            return (200, page([
                #"{"id":"\#(nicID)","name":"web-01-nic","properties":{"virtualMachine":{"id":"\#(vmID)"},"ipConfigurations":[{"properties":{"privateIPAddress":"10.0.0.4","subnet":{"id":"\#(hubVNet)/subnets/default"},"primary":true}}]}}"#,
            ]))
        case "\(sub)/providers/Microsoft.Network/bastionHosts":
            return (200, page([
                bastionJSON(spokeBastion, name: "aaa-bastion", sku: "Basic", vnet: spokeVNet),
                bastionJSON(hubBastion, name: "hub-bastion", sku: "Standard", vnet: hubVNet),
            ]))
        default:
            return (404, "{}")
        }
    }
}

/// Qué pidió cada request (para comprobar el orden).
private func label(_ request: ARMStub.Request) -> String {
    let path = request.path
    if path == "/tenants" { return "tenants" }
    if path == "/subscriptions" { return "subscriptions" }
    if path.hasSuffix("/resourcegroups") { return "resourceGroups" }
    if path.hasSuffix("/virtualMachines") { return request.query?.contains("statusOnly=true") == true ? "powerState" : "virtualMachines" }
    if path.hasSuffix("/networkInterfaces") { return "networkInterfaces" }
    if path.hasSuffix("/bastionHosts") { return "bastionHosts" }
    return path
}

private func liveSource(
    _ arm: URLSession, defaults: UserDefaults, scope: AzureSelection? = AzureSelection(tenantID: home, subscriptionID: prod)
) -> AzureExplorerDataSourceLive {
    let client = AzureARMClient(session: arm, sleep: { _ in }) { jwt(tenant: $0) }
    return AzureExplorerDataSourceLive(
        homeTenantID: home, directory: client, arm: client,
        choices: AzureBastionChoiceStore(defaults: defaults), scope: scope)
}

private let explorerAccount = AzureExplorerAccount(id: "profile-azure", displayName: "a…@contoso.com")

@MainActor
private func explorer(
    _ source: AzureExplorerDataSourceLive
) -> (ExplorerViewModel, ExplorerWindowController) {
    let viewModel = ExplorerViewModel(isSignedIn: false, azureAccount: explorerAccount, azureDataSource: source)
    return (viewModel, ExplorerWindowController(viewModel: viewModel, dataSourceLabel: "Azure"))
}

@Suite("Azure Explorer live data source (GH-98)")
@MainActor
struct AzureExplorerLiveTests {
    @Test func populatesTheTreeFromARMInRequestOrder() async throws {
        let store = TestDefaults()
        let (arm, seen) = inventoryARM()
        let (viewModel, controller) = explorer(liveSource(arm, defaults: store.defaults))

        try await viewModel.reloadAzure().get()

        #expect(seen().map(label) == [
            "tenants", "subscriptions", "resourceGroups", "virtualMachines", "networkInterfaces",
            "bastionHosts", "powerState",
        ])
        // Cada petición con el token de `az` de su tenant; ninguna fuera de ARM.
        #expect(Set(seen().compactMap(\.authorization)) == ["Bearer \(jwt(tenant: home))"])

        #expect(controller.selectNode(id: "azure:tenant:\(home)"))
        #expect(controller.selectedNode?.title == "Contoso")
        #expect(controller.selectNode(id: "azure:subscription:\(prod)"))
        #expect(!controller.selectNode(id: "azure:subscription:\(dev)"))  // fuera del ámbito activo
        #expect(controller.selectNode(id: "azure:resource-group:compute-rg"))
        #expect(controller.selectNode(id: "azure:resource-group:net-rg"))
        #expect(controller.selectNode(id: "azure:vm:\(vmID)"))
        #expect(controller.selectedNode?.title == "web-01 — Running")
        let properties = Dictionary(uniqueKeysWithValues: controller.propertiesPane.rows.map { ($0.label, $0.value) })
        #expect(properties["Operating system"] == "Linux")
        #expect(properties["Private IP"] == "10.0.0.4")
        #expect(properties["Power state"] == "Running")
        // El Bastion de la VNet de la VM se asigna solo; el otro es solo candidato.
        #expect(properties["Bastion"] == "hub-bastion")
        #expect(properties["Connect"] == "Available")
        let selector = try #require(controller.propertiesPane.bastionSelector)
        #expect(selector.numberOfItems == 3)
        #expect(selector.itemTitle(at: 1).contains("hub-bastion"))
        #expect(selector.itemTitle(at: 2).contains("aaa-bastion"))
        #expect(controller.selectNode(id: "azure:bastion:\(hubBastion)"))
        #expect(controller.selectNode(id: "azure:bastion:\(spokeBastion)"))
        #expect(viewModel.statusSummary(source: "Azure") == "Azure — 1 máquina virtual")

        // Caché por tenant/suscripción: recargar no repite peticiones.
        let count = seen().count
        try await viewModel.reloadAzure().get()
        #expect(seen().count == count)
    }

    @Test func tenantScopeShowsEverySubscriptionOfTheTenant() async throws {
        let store = TestDefaults()
        let (arm, seen) = inventoryARM()
        let (viewModel, controller) = explorer(
            liveSource(arm, defaults: store.defaults, scope: AzureSelection(tenantID: home, subscriptionID: nil)))
        try await viewModel.reloadAzure().get()

        #expect(controller.selectNode(id: "azure:subscription:\(prod)"))
        #expect(controller.selectNode(id: "azure:subscription:\(dev)"))
        #expect(controller.selectNode(id: "azure:vm:\(vmID)"))
        #expect(seen().contains { $0.path == "/subscriptions/\(dev)/resourcegroups" })
    }

    @Test func bastionChoicePersistsPerProfileAndNeverCrossesProfiles() async throws {
        let profileA = TestDefaults()
        let profileB = TestDefaults()
        let (arm, _) = inventoryARM()
        let sourceA = liveSource(arm, defaults: profileA.defaults)
        let (viewModel, controller) = explorer(sourceA)
        try await viewModel.reloadAzure().get()

        try await viewModel.selectAzureBastion(id: spokeBastion, forVirtualMachineID: vmID).get()
        #expect(await sourceA.selectedBastionID(forVirtualMachineID: vmID) == spokeBastion)
        #expect(profileA.defaults.string(forKey: AzureBastionChoiceStore.key(forVirtualMachineID: vmID)) == spokeBastion)
        #expect(controller.selectNode(id: "azure:vm:\(vmID)"))
        // Basic: se puede elegir, pero Connect explica por qué no.
        #expect(controller.selectedNode?.properties.first { $0.label == "Connect" }?.value == "SKU Basic sin Native Client")

        // Otro perfil (otra suite): sigue con la asignación automática.
        let (otherViewModel, otherController) = explorer(liveSource(arm, defaults: profileB.defaults))
        try await otherViewModel.reloadAzure().get()
        #expect(otherController.selectNode(id: "azure:vm:\(vmID)"))
        #expect(otherController.selectedNode?.properties.first { $0.label == "Bastion" }?.value == "hub-bastion")

        // Reabrir el perfil A (nueva conexión) recupera su elección; "Sin asignar" también se respeta.
        let reopened = liveSource(arm, defaults: profileA.defaults)
        let (reopenedViewModel, _) = explorer(reopened)
        try await reopenedViewModel.reloadAzure().get()
        #expect(await reopened.selectedBastionID(forVirtualMachineID: vmID) == spokeBastion)
        try await reopened.selectBastion(id: nil, forVirtualMachineID: vmID)
        #expect(await reopened.selectedBastionID(forVirtualMachineID: vmID) == nil)

        // Un ID que no es candidato se rechaza.
        await #expect(throws: AzureExplorerLoadError.bastionNotAvailable) {
            try await reopened.selectBastion(id: "/subscriptions/\(prod)/x", forVirtualMachineID: vmID)
        }
    }

    @Test func armPermissionErrorIsActionableAndLeaksNoToken() async {
        let store = TestDefaults()
        let (arm, _) = inventoryARM(groupsStatus: 403)
        let (viewModel, controller) = explorer(liveSource(arm, defaults: store.defaults))

        if case .success = await viewModel.reloadAzure() { Issue.record("Expected 403 failure") }

        #expect(controller.selectNode(id: "azure:status"))
        let action = controller.selectedNode?.properties.first { $0.label == "Action" }?.value ?? ""
        #expect(action.contains("HTTP 403, AuthorizationFailed"))
        #expect(action.contains("Pide el rol Reader"))
        #expect(!action.contains("Bearer") && !action.contains(jwt(tenant: home)))
        #expect(!controller.selectNode(id: "azure:vm:\(vmID)"))
    }

    @Test func mapsARMPowerStates() {
        // Estados conocidos mapeados; uno desconocido se muestra tal cual.
        #expect(AzureExplorerDataSourceLive.powerState("deallocated") == .deallocated)
        #expect(AzureExplorerDataSourceLive.powerState("deallocating") == .stopping)
        #expect(AzureExplorerDataSourceLive.powerState("hibernated") == .unknown("hibernated"))
    }
}

@Suite("Azure Explorer wiring in the profile session (GH-98)", .serialized)
@MainActor
struct AzureExplorerWiringTests {
    private func coordinator(
        az: StubAz, arm: URLSession, index: TestDefaults
    ) -> (ProfileCoordinator, ProfileStore) {
        let store = ProfileStore(defaults: index.defaults)
        let dependencies = AzureProfileSession.Dependencies(runner: az, armSession: arm, showsWindow: false)
        return (ProfileCoordinator(store: store, migrationCompleted: true, azureDependencies: dependencies), store)
    }

    @Test func azureProfileFillsTheExplorerTreeWithRealData() async throws {
        let index = TestDefaults()
        let (arm, seen) = inventoryARM()
        let (coordinator, _) = coordinator(az: StubAz(accountList: prodAccounts), arm: arm, index: index)
        let session = try #require(coordinator.createProfile(named: "Azure", provider: .azure) as? AzureProfileSession)
        defer { UserDefaults.standard.removePersistentDomain(forName: session.environment.explorerSuite!) }

        await session.connectTask?.value
        await session.explorerLoad?.value

        // El Explorer es la ventana principal del perfil.
        let explorer = try #require(session.explorerController)
        #expect(session.window === explorer.window && session.owns(session.windowController?.window))
        #expect(explorer.selectNode(id: "azure:account:\(session.id.rawValue)"))
        #expect(explorer.selectedNode?.title == "a…@contoso.com")
        #expect(explorer.selectNode(id: "azure:subscription:\(prod)"))  // suscripción por defecto de `az`
        #expect(explorer.selectNode(id: "azure:vm:\(vmID)"))
        #expect(explorer.selectedNode?.title == "web-01 — Running")
        #expect(!explorer.selectNode(id: "cloud"))  // sin sección Google
        #expect(explorer.accountText.contains("a…@contoso.com"))
        #expect(seen().contains { label($0) == "powerState" })

        // Cambiar la suscripción activa en Cuenta Azure recarga el árbol con ese ámbito.
        #expect(session.model.select(tenantID: home, subscriptionID: dev))
        await session.explorerLoad?.value
        #expect(explorer.selectNode(id: "azure:subscription:\(dev)"))
        #expect(!explorer.selectNode(id: "azure:subscription:\(prod)"))

        // Sign Out: el árbol vuelve a "Sin sesión Azure", sin inventario.
        await session.model.disconnect()
        #expect(session.explorerViewModel.azureState == .noSession)
        #expect(session.explorerDataSource == nil)
        session.window?.close()
        #expect(!coordinator.isOpen(session.id))
    }

    @Test func withoutAzTheTreeShowsTheCTAAndNeverCallsARM() async throws {
        let index = TestDefaults()
        let (arm, seen) = inventoryARM()
        let (coordinator, _) = coordinator(az: StubAz(installed: false, accountList: "[]"), arm: arm, index: index)
        let session = try #require(coordinator.createProfile(named: "Azure", provider: .azure) as? AzureProfileSession)
        defer { UserDefaults.standard.removePersistentDomain(forName: session.environment.explorerSuite!) }

        await session.connectTask?.value

        let explorer = try #require(session.explorerController)
        #expect(session.explorerViewModel.azureState == .noSession)
        #expect(explorer.selectNode(id: "azure:status"))
        #expect(explorer.selectedNode?.title == "Sin sesión Azure")
        #expect(explorer.selectedNode?.properties.first { $0.label == "Action" }?.value
            == "Instala Azure CLI y ejecuta `az login`")
        #expect(!explorer.selectNode(id: "azure:tenant:\(home)"))
        #expect(session.windowController?.pane == .signIn)
        #expect(seen().isEmpty)
        session.window?.close()
    }

    @Test func googleProfilesHaveNoAzureSection() throws {
        let id = ProfileID.generate()
        let environment = ProfileEnvironment(id: id, migrationCompleted: true)
        let session = try #require(ProfileSession(
            id: id, descriptor: ProfileDescriptor(id: id, displayName: "Google"), environment: environment))
        defer { UserDefaults.standard.removePersistentDomain(forName: environment.explorerSuite!) }

        #expect(session.provider == .google)
        #expect(session.viewModel.azureState == nil)
        let controller = ExplorerWindowController(viewModel: session.viewModel, dataSourceLabel: "GCP")
        #expect(!controller.selectNode(id: "azure"))
        #expect(!controller.selectNode(id: "azure:status"))
        #expect(session.viewModel.statusSummary(source: "GCP") == ExplorerViewModel.signedOutSummary)
    }
}
