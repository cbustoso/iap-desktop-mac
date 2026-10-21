import AuthKit
import AzureClient
import ExplorerUI
import Foundation
import OSLog

/// GH-98: `AzureExplorerDataSource` real de UN perfil Azure. ARM REST con el
/// token de la sesión `az login` (vía `AzureCredentialFacade`); ExplorerUI no
/// ve ni `az` ni ARM. Una instancia por conexión de la sesión: Refresh o un
/// nuevo `az login` crean otra, así que la caché nunca cruza cuentas ni perfiles.
///
/// Caché por tenant (tenants, suscripciones) y por suscripción (RGs, VMs+NICs,
/// Bastions, power state): el ViewModel pide por nodo, pero cada listado ARM
/// se hace una sola vez por suscripción. Un fallo no se cachea (el siguiente
/// reload lo reintenta).
///
/// El árbol se limita al ámbito activo del perfil (tenant/suscripción elegidos
/// en la ventana Cuenta Azure, menú Sign In…); sin ámbito, todos los tenants.
actor AzureExplorerDataSourceLive: AzureExplorerDataSource {
    private let homeTenantID: String
    private let directory: any AzureAccountDirectory
    private let arm: AzureARMClient
    private let choices: AzureBastionChoiceStore
    private var scope: AzureSelection?

    private var tenantsTask: Task<[AzureTenant], any Error>?
    private var subscriptionTasks: [String: Task<[AzureSubscription], any Error>] = [:]
    private var groupTasks: [String: Task<[AzureResourceGroup], any Error>] = [:]
    private var machineTasks: [String: Task<Machines, any Error>] = [:]
    private var bastionTasks: [String: Task<[AzureBastion]?, Never>] = [:]
    private var statusTasks: [String: Task<[String: String], Never>] = [:]
    /// VM → suscripción/tenant/VNet (lo rellena `listVirtualMachines`).
    private var machineContext: [String: MachineContext] = [:]

    private static let log = Logger(subsystem: "com.iapdesktop.mac", category: "azure.explorer")

    /// VMs de una suscripción con la NIC primaria de cada una (si se pudo leer).
    private struct Machines: Sendable {
        let vms: [AzureVM]
        let nics: [String: AzureNIC]
    }

    private struct MachineContext: Sendable {
        let subscriptionID: String
        let tenantID: String
        let virtualNetworkID: String?
    }

    init(
        homeTenantID: String, directory: any AzureAccountDirectory, arm: AzureARMClient,
        choices: AzureBastionChoiceStore, scope: AzureSelection?
    ) {
        self.homeTenantID = homeTenantID
        self.directory = directory
        self.arm = arm
        self.choices = choices
        self.scope = scope
    }

    /// Cambia el ámbito (tenant/suscripción activos). Lo ya cargado se conserva.
    func setScope(_ scope: AzureSelection?) {
        self.scope = scope
    }

    // MARK: - AzureExplorerDataSource

    func listTenants() async throws -> [AzureExplorerTenant] {
        let tenants = try await allTenants()
        let visible = scope.map { scope in tenants.filter { Self.same($0.tenantID, scope.tenantID) } } ?? tenants
        return visible.map {
            AzureExplorerTenant(id: $0.tenantID, displayName: $0.displayName, defaultDomain: $0.defaultDomain)
        }
    }

    func listSubscriptions(forTenantID tenantID: String) async throws -> [AzureExplorerSubscription] {
        var subscriptions = try await subscriptions(tenantID: tenantID)
        if let scope, Self.same(scope.tenantID, tenantID), let only = scope.subscriptionID {
            subscriptions = subscriptions.filter { Self.same($0.subscriptionID, only) }
        } else if scope == nil, let tenants = try? await allTenants() {
            // Lighthouse: una suscripción delegada se muestra bajo su tenant dueño.
            subscriptions = subscriptions.filter { subscription in
                guard let owner = subscription.tenantID, !Self.same(owner, tenantID) else { return true }
                return !tenants.contains { Self.same($0.tenantID, owner) }
            }
        }
        return subscriptions.map {
            AzureExplorerSubscription(id: $0.subscriptionID, displayName: $0.displayName, state: $0.state)
        }
    }

    func listResourceGroups(
        forSubscriptionID subscriptionID: String, tenantID: String
    ) async throws -> [AzureExplorerResourceGroup] {
        let key = Self.key(tenantID, subscriptionID)
        let task = groupTasks[key] ?? Task { [arm] in
            try await arm.resourceGroups(subscriptionID: subscriptionID, tenantID: tenantID)
        }
        groupTasks[key] = task
        do {
            return try await task.value.map { AzureExplorerResourceGroup(name: $0.name, location: $0.location) }
        } catch {
            if groupTasks[key] == task { groupTasks[key] = nil }
            throw Self.failure(error, loading: "los resource groups de la suscripción \(subscriptionID)")
        }
    }

    func listVirtualMachines(
        forResourceGroup resourceGroup: String, subscriptionID: String, tenantID: String
    ) async throws -> [AzureExplorerVirtualMachine] {
        let machines = try await machines(subscriptionID: subscriptionID, tenantID: tenantID)
        return machines.vms
            .filter { Self.same($0.resourceGroup ?? "", resourceGroup) }
            .map { vm in
                let nic = vm.primaryNetworkInterfaceID.flatMap { machines.nics[ARMResourceID.normalized($0)] }
                machineContext[ARMResourceID.normalized(vm.id)] = MachineContext(
                    subscriptionID: subscriptionID, tenantID: tenantID, virtualNetworkID: nic?.virtualNetworkID)
                return AzureExplorerVirtualMachine(
                    id: vm.id, name: vm.name, location: vm.location,
                    operatingSystem: vm.osType.flatMap { GuestOS(rawValue: $0.lowercased()) },
                    privateIPAddress: nic?.primaryConfiguration?.privateIPAddress)
            }
    }

    /// Candidatos: los Bastion de la suscripción, primero los de la VNet de la
    /// VM (los demás pueden servirla por peering: el usuario elige a mano).
    func listBastions(
        forVirtualMachineID virtualMachineID: String, resourceGroup: String,
        subscriptionID: String, tenantID: String
    ) async throws -> [AzureExplorerBastion] {
        let bastions = await bastions(subscriptionID: subscriptionID, tenantID: tenantID) ?? []
        let vnet = machineContext[ARMResourceID.normalized(virtualMachineID)]?.virtualNetworkID
        return Self.ranked(bastions, virtualNetworkID: vnet).map(Self.explorerBastion)
    }

    func powerState(
        forVirtualMachineID virtualMachineID: String, subscriptionID: String, tenantID: String
    ) async throws -> AzureVMPowerState? {
        // Tras los Bastion (misma suscripción): orden de peticiones estable.
        _ = await bastions(subscriptionID: subscriptionID, tenantID: tenantID)
        let key = Self.key(tenantID, subscriptionID)
        let task = statusTasks[key] ?? Task { [arm] in
            do {
                let statuses = try await arm.virtualMachineStatuses(subscriptionID: subscriptionID, tenantID: tenantID)
                return Dictionary(statuses.compactMap { status in
                    status.powerState.map { (ARMResourceID.normalized(status.id), $0) }
                }, uniquingKeysWith: { first, _ in first })
            } catch {
                // Degrada a "No disponible": no impide ver ni conectar la VM.
                Self.log.notice("azure power state unavailable cause=\(Self.cause(error), privacy: .public)")
                return [:]
            }
        }
        statusTasks[key] = task
        return await task.value[ARMResourceID.normalized(virtualMachineID)].map(Self.powerState)
    }

    /// La elección guardada si sigue siendo un candidato; si no, el Bastion de
    /// la VNet de la VM (preferido el que tiene native client). Nunca inventa uno.
    func selectedBastionID(forVirtualMachineID virtualMachineID: String) async -> String? {
        let choice = choices.choice(forVirtualMachineID: virtualMachineID)
        if choice == .some(nil) { return nil }  // "Sin asignar" explícito
        guard let context = machineContext[ARMResourceID.normalized(virtualMachineID)] else { return nil }
        let bastions = await bastions(subscriptionID: context.subscriptionID, tenantID: context.tenantID) ?? []
        if case .some(.some(let id)) = choice, let stored = bastions.first(where: { Self.same($0.id, id) }) {
            return stored.id
        }
        guard let vnet = context.virtualNetworkID else { return nil }
        return Self.ranked(bastions.filter { Self.serves($0, vnet) }, virtualNetworkID: vnet).first?.id
    }

    func selectBastion(id: String?, forVirtualMachineID virtualMachineID: String) async throws {
        if let id {
            guard let context = machineContext[ARMResourceID.normalized(virtualMachineID)],
                  let bastions = await bastions(subscriptionID: context.subscriptionID, tenantID: context.tenantID),
                  bastions.contains(where: { Self.same($0.id, id) })
            else { throw AzureExplorerLoadError.bastionNotAvailable }
        }
        choices.save(id, forVirtualMachineID: virtualMachineID)
    }

    // MARK: - Cachés

    private func allTenants() async throws -> [AzureTenant] {
        let task = tenantsTask ?? Task { [directory, homeTenantID] in
            try await directory.tenants(homeTenantID: homeTenantID)
        }
        tenantsTask = task
        do {
            return try await task.value
        } catch {
            if tenantsTask == task { tenantsTask = nil }
            throw Self.failure(error, loading: "los tenants de la sesión az")
        }
    }

    private func subscriptions(tenantID: String) async throws -> [AzureSubscription] {
        let key = ARMResourceID.normalized(tenantID)
        let task = subscriptionTasks[key] ?? Task { [directory] in
            try await directory.subscriptions(tenantID: tenantID)
                .filter(\.isUsable)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
        subscriptionTasks[key] = task
        do {
            return try await task.value
        } catch {
            if subscriptionTasks[key] == task { subscriptionTasks[key] = nil }
            throw Self.failure(error, loading: "las suscripciones del tenant \(tenantID)")
        }
    }

    /// VMs (imprescindibles) + NICs (degradan: sin IP privada ni VNet).
    private func machines(subscriptionID: String, tenantID: String) async throws -> Machines {
        let key = Self.key(tenantID, subscriptionID)
        let task = machineTasks[key] ?? Task { [arm] in
            let vms = try await arm.virtualMachines(subscriptionID: subscriptionID, tenantID: tenantID)
            let nics: [AzureNIC]
            do {
                nics = try await arm.networkInterfaces(subscriptionID: subscriptionID, tenantID: tenantID)
            } catch {
                Self.log.notice("azure nics unavailable cause=\(Self.cause(error), privacy: .public)")
                nics = []
            }
            return Machines(vms: vms, nics: Dictionary(
                nics.map { (ARMResourceID.normalized($0.id), $0) }, uniquingKeysWith: { first, _ in first }))
        }
        machineTasks[key] = task
        do {
            return try await task.value
        } catch {
            if machineTasks[key] == task { machineTasks[key] = nil }
            throw Self.failure(error, loading: "las máquinas virtuales de la suscripción \(subscriptionID)")
        }
    }

    /// `nil` si no se pudieron listar (sin Reader sobre los Bastion): la VM
    /// queda sin candidatos en vez de tirar el árbol.
    private func bastions(subscriptionID: String, tenantID: String) async -> [AzureBastion]? {
        let key = Self.key(tenantID, subscriptionID)
        let task = bastionTasks[key] ?? Task { [arm] in
            do {
                return try await arm.bastionHosts(subscriptionID: subscriptionID, tenantID: tenantID)
            } catch {
                Self.log.notice("azure bastions unavailable cause=\(Self.cause(error), privacy: .public)")
                return nil
            }
        }
        bastionTasks[key] = task
        return await task.value
    }

    // MARK: - Lógica pura

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func key(_ tenantID: String, _ subscriptionID: String) -> String {
        "\(tenantID.lowercased())/\(subscriptionID.lowercased())"
    }

    private static func serves(_ bastion: AzureBastion, _ virtualNetworkID: String) -> Bool {
        bastion.virtualNetworkIDs.contains { same($0, virtualNetworkID) }
    }

    /// VNet de la VM primero, luego native client, luego nombre.
    static func ranked(_ bastions: [AzureBastion], virtualNetworkID: String?) -> [AzureBastion] {
        bastions.sorted { lhs, rhs in
            func rank(_ bastion: AzureBastion) -> (Int, Int) {
                (virtualNetworkID.map { serves(bastion, $0) } == true ? 0 : 1, bastion.supportsNativeClient ? 0 : 1)
            }
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func explorerBastion(_ bastion: AzureBastion) -> AzureExplorerBastion {
        AzureExplorerBastion(id: bastion.id, name: bastion.name, sku: bastion.sku, enableTunneling: bastion.enableTunneling)
    }

    static func powerState(_ code: String) -> AzureVMPowerState {
        switch code.lowercased() {
        case "running": .running
        case "starting": .starting
        case "stopping", "deallocating": .stopping
        case "stopped": .stopped
        case "deallocated": .deallocated
        default: .unknown(code)
        }
    }

    /// Para logs: tipo y estado HTTP, nunca cuerpos ni tokens.
    private static func cause(_ error: any Error) -> String {
        switch error {
        case AzureARMError.http(let status, let code, _): "http=\(status) code=\(code ?? "-")"
        case AzureARMError.throttled(let status): "throttled=\(status)"
        case let error as AzCliError: "az=\(String(describing: error))"
        default: String(describing: type(of: error))
        }
    }

    private static func failure(_ error: any Error, loading what: String) -> AzureExplorerLoadError {
        log.error("azure explorer load failed cause=\(cause(error), privacy: .public)")
        return AzureExplorerLoadError(error, loading: what)
    }
}

/// Error del árbol Azure con su acción concreta (la muestra el nodo de estado).
struct AzureExplorerLoadError: LocalizedError, Equatable {
    let errorDescription: String?
    let recoverySuggestion: String?

    static let bastionNotAvailable = AzureExplorerLoadError(
        description: "Ese Bastion ya no es un candidato para esta VM",
        suggestion: "Pulsa Refresh (⌘R) y elige otro Bastion.")

    private init(description: String, suggestion: String) {
        errorDescription = description
        recoverySuggestion = suggestion
    }

    init(_ error: any Error, loading what: String) {
        let refresh = "pulsa Refresh (⌘R)"
        switch error {
        case let error as AzCliError:
            switch error {
            case .notInstalled, .notLoggedIn:
                self.init(description: error.userMessage,
                          suggestion: "Instala Azure CLI y ejecuta `az login`, y \(refresh).")
            default:
                self.init(description: error.userMessage, suggestion: "Ejecuta `az login` en Terminal y \(refresh).")
            }
        case AzureARMError.http(401, _, _):
            self.init(description: "Azure Resource Manager rechazó el token de la sesión az al leer \(what) (HTTP 401)",
                      suggestion: "Ejecuta `az login` de nuevo y \(refresh).")
        case AzureARMError.http(403, let code, _):
            self.init(description: "Sin permiso para leer \(what) (HTTP 403\(code.map { ", \($0)" } ?? ""))",
                      suggestion: "Pide el rol Reader en la suscripción o el resource group, "
                          + "o elige otra suscripción en la ventana Cuenta Azure (menú Sign In…).")
        case AzureARMError.http(404, let code, _):
            self.init(description: "Azure no encontró \(what) (HTTP 404\(code.map { ", \($0)" } ?? ""))",
                      suggestion: "Elige otra suscripción y \(refresh).")
        case AzureARMError.http(let status, _, _):
            self.init(description: "Azure Resource Manager respondió HTTP \(status) al leer \(what)",
                      suggestion: "Vuelve a intentarlo: \(refresh).")
        case AzureARMError.throttled(let status):
            self.init(description: "Azure Resource Manager limitó las peticiones (HTTP \(status))",
                      suggestion: "Espera unos minutos y \(refresh).")
        case AzureARMError.network:
            self.init(description: "No se pudo contactar con management.azure.com",
                      suggestion: "Comprueba la conexión o el proxy y \(refresh).")
        default:
            self.init(description: "Respuesta inesperada de Azure Resource Manager al leer \(what)",
                      suggestion: "Vuelve a intentarlo: \(refresh). Si persiste, exporta los logs.")
        }
    }
}

/// Bastion elegido por VM, en la suite `explorer` del perfil (aislado por
/// perfil; `purge` lo borra con él). Solo IDs ARM. Cadena vacía = "Sin asignar"
/// explícito (no se vuelve a autoasignar el de la VNet).
struct AzureBastionChoiceStore: @unchecked Sendable {
    // UserDefaults es thread-safe; @unchecked solo porque el SDK no lo marca Sendable.
    let defaults: UserDefaults

    static func key(forVirtualMachineID id: String) -> String { "azure.bastion.\(ARMResourceID.normalized(id))" }

    /// `nil`: sin elección; `.some(nil)`: "Sin asignar"; `.some(id)`: ese Bastion.
    func choice(forVirtualMachineID id: String) -> String?? {
        guard let stored = defaults.string(forKey: Self.key(forVirtualMachineID: id)) else { return nil }
        return .some(stored.isEmpty ? nil : stored)
    }

    func save(_ bastionID: String?, forVirtualMachineID id: String) {
        defaults.set(bastionID ?? "", forKey: Self.key(forVirtualMachineID: id))
    }
}
