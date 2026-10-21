// ExplorerUI: nodo del árbol + presentación pura (icono, propiedades, menú
// contextual). Sin AppKit para que sea testeable sin ventana.

public enum AzureExplorerStatus: Hashable, Sendable {
    case noSession
    case loading
    case error(String)

    var title: String {
        switch self {
        case .noSession: "Sin sesión Azure"
        case .loading: "Cargando…"
        case .error: "Error al cargar Azure"
        }
    }
}

/// Nodo del árbol para las secciones Google Cloud y Microsoft Azure.
public enum ExplorerNode: Hashable, Sendable {
    case cloud(projectCount: Int, instanceCount: Int)
    case project(ProjectInfo)
    case zone(ZoneInfo)
    case instance(InstanceInfo)
    case azure
    case azureStatus(AzureExplorerStatus)
    case azureAccount(AzureExplorerAccount)
    case azureTenant(AzureExplorerTenant)
    case azureSubscription(AzureExplorerSubscription)
    case azureResourceGroup(AzureExplorerResourceGroup)
    case azureVirtualMachine(AzureExplorerVMNode)
    case azureBastion(AzureExplorerBastion, selected: Bool)

    /// Identidad estable entre recargas (el contenido filtrado cambia, el id no).
    public var id: String {
        switch self {
        case .cloud: return "cloud"
        case .project(let p): return "project:\(p.id)"
        case .zone(let z): return "zone:\(z.id)"
        case .instance(let i): return "instance:\(i.id)"
        case .azure: return "azure"
        case .azureStatus: return "azure:status"
        case .azureAccount(let account): return "azure:account:\(account.id)"
        case .azureTenant(let tenant): return "azure:tenant:\(tenant.id)"
        case .azureSubscription(let subscription): return "azure:subscription:\(subscription.id)"
        case .azureResourceGroup(let group): return "azure:resource-group:\(group.name)"
        case .azureVirtualMachine(let node): return "azure:vm:\(node.virtualMachine.id)"
        case .azureBastion(let bastion, _): return "azure:bastion:\(bastion.id)"
        }
    }

    public var title: String {
        switch self {
        case .cloud: return "Google Cloud"
        case .project(let p): return p.name
        case .zone(let z): return z.name
        case .instance(let i): return i.name
        case .azure: return "Microsoft Azure"
        case .azureStatus(let status): return status.title
        case .azureAccount(let account): return account.displayName
        case .azureTenant(let tenant): return tenant.displayName ?? tenant.defaultDomain ?? tenant.id
        case .azureSubscription(let subscription): return subscription.displayName
        case .azureResourceGroup(let group): return group.name
        case .azureVirtualMachine(let node):
            guard let state = node.powerState else { return node.virtualMachine.name }
            return "\(node.virtualMachine.name) — \(state.displayName)"
        case .azureBastion(let bastion, let selected):
            return selected ? "\(bastion.name) (selected)" : bastion.name
        }
    }

    /// SF Symbol por tipo de nodo (paridad con los iconos del IAP Desktop).
    public var symbolName: String {
        switch self {
        case .cloud: return "cloud"
        case .project: return "folder"
        case .zone: return "globe"
        case .instance(let i):
            switch i.os {
            case .linux: return "terminal"
            case .windows: return "pc"
            }
        case .azure: return "cloud"
        case .azureStatus(let status):
            switch status {
            case .noSession: return "person.crop.circle.badge.exclamationmark"
            case .loading: return "hourglass"
            case .error: return "exclamationmark.triangle"
            }
        case .azureAccount: return "person.crop.circle"
        case .azureTenant: return "building.2"
        case .azureSubscription: return "rectangle.stack"
        case .azureResourceGroup: return "folder"
        case .azureVirtualMachine(let node):
            return node.virtualMachine.operatingSystem == .windows ? "pc" : "terminal"
        case .azureBastion: return "shield.lefthalf.filled"
        }
    }

    /// Proyecto al que pertenece el nodo (para "Refresh project").
    public var projectName: String? {
        switch self {
        case .cloud: return nil
        case .project(let p): return p.name
        case .zone(let z): return z.project
        case .instance(let i): return i.project
        case .azure, .azureStatus, .azureAccount, .azureTenant, .azureSubscription,
             .azureResourceGroup, .azureVirtualMachine, .azureBastion:
            return nil
        }
    }

    /// Filas del panel Properties. Nunca vacío para un nodo seleccionado.
    public var properties: [PropertyRow] {
        switch self {
        case .cloud(let projects, let instances):
            return [
                PropertyRow("Name", "Google Cloud"),
                PropertyRow("Type", "Cloud"),
                PropertyRow("Projects", "\(projects)"),
                PropertyRow("Instances", "\(instances)"),
            ]
        case .project(let p):
            let instances = p.zones.flatMap(\.instances)
            return [
                PropertyRow("Name", p.name),
                PropertyRow("Type", "Project"),
                PropertyRow("Zones", "\(p.zones.count)"),
                PropertyRow("Instances", "\(instances.count)"),
                PropertyRow("Running", "\(instances.filter { $0.status == .running }.count)"),
            ]
        case .zone(let z):
            return [
                PropertyRow("Name", z.name),
                PropertyRow("Type", "Zone"),
                PropertyRow("Project", z.project),
                PropertyRow("Instances", "\(z.instances.count)"),
                PropertyRow("Linux", "\(z.instances.filter { $0.os == .linux }.count)"),
                PropertyRow("Windows", "\(z.instances.filter { $0.os == .windows }.count)"),
            ]
        case .instance(let i):
            return [
                PropertyRow("Name", i.name),
                PropertyRow("Type", "VM instance"),
                PropertyRow("Project", i.project),
                PropertyRow("Zone", i.zone),
                PropertyRow("Operating system", i.os.displayName),
                PropertyRow("Status", i.status.displayName),
                PropertyRow("Session", i.connected ? "Connected" : "Not connected"),
                PropertyRow("Resource", "projects/\(i.project)/zones/\(i.zone)/instances/\(i.name)"),
            ]
        case .azure:
            return [PropertyRow("Name", "Microsoft Azure"), PropertyRow("Type", "Cloud")]
        case .azureStatus(let status):
            switch status {
            case .noSession:
                return [PropertyRow("Status", "Sin sesión Azure"),
                        PropertyRow("Action", "Instala Azure CLI y ejecuta `az login`")]
            case .loading:
                return [PropertyRow("Status", "Cargando inventario Azure…")]
            case .error(let message):
                return [PropertyRow("Status", "Error"), PropertyRow("Action", message)]
            }
        case .azureAccount(let account):
            return [PropertyRow("Name", account.displayName), PropertyRow("Type", "Azure account"),
                    PropertyRow("Profile ID", account.id),
                    PropertyRow("Username", account.username ?? "No disponible")]
        case .azureTenant(let tenant):
            return [PropertyRow("Name", tenant.displayName ?? "No disponible"),
                    PropertyRow("Type", "Tenant"), PropertyRow("Tenant ID", tenant.id),
                    PropertyRow("Domain", tenant.defaultDomain ?? "No disponible")]
        case .azureSubscription(let subscription):
            return [PropertyRow("Name", subscription.displayName), PropertyRow("Type", "Subscription"),
                    PropertyRow("Subscription ID", subscription.id), PropertyRow("State", subscription.state)]
        case .azureResourceGroup(let group):
            return [PropertyRow("Name", group.name), PropertyRow("Type", "Resource group"),
                    PropertyRow("Location", group.location ?? "No disponible")]
        case .azureVirtualMachine(let node):
            let vm = node.virtualMachine
            let bastion = node.selectedBastion
            return [
                PropertyRow("Name", vm.name), PropertyRow("Type", "Virtual machine"),
                PropertyRow("Operating system", vm.operatingSystem?.displayName ?? "Unknown"),
                PropertyRow("Power state", node.powerState?.displayName ?? "No disponible"),
                PropertyRow("Private IP", vm.privateIPAddress ?? "No disponible"),
                PropertyRow("Resource group", node.resourceGroup.name),
                PropertyRow("Subscription", node.subscription.displayName),
                PropertyRow("Tenant", node.tenant.displayName ?? node.tenant.id),
                PropertyRow("Bastion", bastion?.name ?? "Sin asignar"),
                PropertyRow("Bastion SKU", bastion?.sku ?? "No disponible"),
                PropertyRow("Native Client", bastion.map { $0.enableTunneling ? "Enabled" : "Disabled" } ?? "No disponible"),
                PropertyRow("Connect", node.connectDisabledReason ?? "Available"),
                PropertyRow("Resource", vm.id),
            ]
        case .azureBastion(let bastion, let selected):
            return [PropertyRow("Name", bastion.name), PropertyRow("Type", "Bastion host"),
                    PropertyRow("SKU", bastion.sku),
                    PropertyRow("Native Client", bastion.enableTunneling ? "Enabled" : "Disabled"),
                    PropertyRow("Selected", selected ? "Yes" : "No"), PropertyRow("Resource", bastion.id)]
        }
    }
}

public struct PropertyRow: Hashable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

extension GuestOS {
    public var displayName: String {
        switch self {
        case .linux: return "Linux"
        case .windows: return "Windows"
        }
    }

    /// Hito en el que llega la conexión para este SO.
    public var connectMilestone: String {
        switch self {
        case .linux: return "M1 (SSH)"
        case .windows: return "M2 (RDP)"
        }
    }
}

extension InstanceStatus {
    public var displayName: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Menú contextual

/// Comandos del menú contextual (subconjunto del IAP Desktop).
public enum ExplorerCommand: String, Sendable, CaseIterable {
    case connect
    case connectAsUser
    case connectionSettings
    /// Solo instancias Windows (paridad "Generate Windows logon credentials").
    case generateWindowsCredentials
    case softwarePackages
    case refreshProject
    case properties

    public var title: String {
        switch self {
        case .connect: return "Connect"
        case .connectAsUser: return "Connect as user…"
        case .connectionSettings: return "Connection settings…"
        case .generateWindowsCredentials: return "Generate Windows credentials…"
        case .softwarePackages: return "Software packages"
        case .refreshProject: return "Refresh project"
        case .properties: return "Properties"
        }
    }

    public var symbolName: String {
        switch self {
        case .connect: return "play.display"
        case .connectAsUser: return "person.badge.key"
        case .connectionSettings: return "slider.horizontal.3"
        case .generateWindowsCredentials: return "key"
        case .softwarePackages: return "shippingbox"
        case .refreshProject: return "arrow.clockwise"
        case .properties: return "info.circle"
        }
    }

    /// Hito en el que se implementa; `nil` = disponible ya.
    public var milestone: String? {
        switch self {
        case .connect: return "M1"
        case .connectAsUser, .connectionSettings: return "M2"
        case .generateWindowsCredentials, .softwarePackages, .refreshProject, .properties: return nil
        }
    }

    public var isAvailable: Bool { milestone == nil }
}

public enum ContextMenuEntry: Hashable, Sendable {
    case command(ExplorerCommand)
    case separator
}

public enum ExplorerContextMenu {
    public static func entries(for node: ExplorerNode) -> [ContextMenuEntry] {
        switch node {
        case .instance(let instance):
            let credentials: [ContextMenuEntry] = instance.os == .windows
                ? [.command(.generateWindowsCredentials)] : []
            return [.command(.connect), .command(.connectAsUser), .command(.connectionSettings)]
                + credentials + [.command(.softwarePackages),
                .separator,
                .command(.refreshProject),
                .separator,
                .command(.properties),
            ]
        case .zone:
            return [.command(.softwarePackages), .separator, .command(.refreshProject),
                    .separator, .command(.properties)]
        case .project:
            return [.command(.refreshProject), .separator, .command(.properties)]
        case .cloud:
            return [.command(.properties)]
        case .azureVirtualMachine:
            return [.command(.connect), .separator, .command(.properties)]
        case .azure, .azureStatus, .azureAccount, .azureTenant, .azureSubscription,
             .azureResourceGroup, .azureBastion:
            return [.command(.properties)]
        }
    }
}
