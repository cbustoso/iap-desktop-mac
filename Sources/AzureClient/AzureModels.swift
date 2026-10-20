// GH-90 (specs/azure/azure-bastion-research.md §2): modelos ARM mínimos para el
// árbol tenant → suscripción → resource group → VM, más NIC y Bastion para
// emparejar cada VM con su Bastion. Solo los campos que usamos.
import Foundation

/// Utilidades de IDs ARM (`/subscriptions/…/resourceGroups/…/providers/…`).
/// ARM trata los IDs sin distinguir mayúsculas: se comparan normalizados.
public enum ARMResourceID {
    public static func normalized(_ id: String) -> String { id.lowercased() }

    /// VNet de un ID de subnet: el prefijo hasta `/subnets/`.
    public static func virtualNetwork(ofSubnet subnetID: String) -> String? {
        guard let range = subnetID.range(of: "/subnets/", options: .caseInsensitive) else { return nil }
        return String(subnetID[..<range.lowerBound])
    }

    /// Resource group de un ID (`…/resourceGroups/<rg>/…`).
    public static func resourceGroup(of id: String) -> String? {
        let parts = id.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = parts.firstIndex(where: { $0.caseInsensitiveCompare("resourceGroups") == .orderedSame }),
              index + 1 < parts.count
        else { return nil }
        return String(parts[index + 1])
    }

    /// ID ARM absoluto usable como path: sin query, fragmento ni `..`.
    public static func isValidPath(_ id: String) -> Bool {
        id.hasPrefix("/subscriptions/") && !id.contains("..") && !id.contains("?") && !id.contains("#")
            && !id.contains("//") && id.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 }
    }
}

public struct AzureTenant: Sendable, Equatable, Decodable {
    public let tenantID: String
    public let displayName: String?
    public let defaultDomain: String?
    /// `Home`, `ProjectedBy` (Lighthouse) o `ManagedBy`.
    public let tenantCategory: String?

    public init(tenantID: String, displayName: String? = nil, defaultDomain: String? = nil, tenantCategory: String? = nil) {
        self.tenantID = tenantID
        self.displayName = displayName
        self.defaultDomain = defaultDomain
        self.tenantCategory = tenantCategory
    }

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenantId"
        case displayName, defaultDomain, tenantCategory
    }
}

public struct AzureSubscription: Sendable, Equatable, Decodable {
    public let subscriptionID: String
    /// Tenant dueño de la suscripción (puede no ser el del token con el que
    /// se listó: suscripciones delegadas por Lighthouse).
    public let tenantID: String?
    public let displayName: String
    /// `Enabled`, `Warned`, `PastDue`, `Disabled` o `Deleted`.
    public let state: String

    public init(subscriptionID: String, tenantID: String?, displayName: String, state: String) {
        self.subscriptionID = subscriptionID
        self.tenantID = tenantID
        self.displayName = displayName
        self.state = state
    }

    /// `Disabled`/`Deleted` son de solo lectura o inexistentes: fuera del árbol.
    public var isUsable: Bool { !["disabled", "deleted"].contains(state.lowercased()) }

    enum CodingKeys: String, CodingKey {
        case subscriptionID = "subscriptionId"
        case tenantID = "tenantId"
        case displayName, state
    }
}

public struct AzureResourceGroup: Sendable, Equatable, Decodable {
    public let id: String
    public let name: String
    public let location: String

    public init(id: String, name: String, location: String) {
        self.id = id
        self.name = name
        self.location = location
    }
}

public struct AzureVM: Sendable, Equatable, Decodable {
    public let id: String
    public let name: String
    public let location: String
    /// `Linux` / `Windows` (de `storageProfile.osDisk.osType`).
    public let osType: String?
    public let vmSize: String?
    public let networkInterfaceIDs: [String]
    /// NIC marcada `primary` o, si ninguna lo está, la primera.
    public let primaryNetworkInterfaceID: String?

    public var resourceGroup: String? { ARMResourceID.resourceGroup(of: id) }

    public init(id: String, name: String, location: String, osType: String? = nil, vmSize: String? = nil,
                networkInterfaceIDs: [String] = [], primaryNetworkInterfaceID: String? = nil) {
        self.id = id
        self.name = name
        self.location = location
        self.osType = osType
        self.vmSize = vmSize
        self.networkInterfaceIDs = networkInterfaceIDs
        self.primaryNetworkInterfaceID = primaryNetworkInterfaceID ?? networkInterfaceIDs.first
    }

    private struct Raw: Decodable {
        struct Properties: Decodable {
            struct Hardware: Decodable { let vmSize: String? }
            struct Storage: Decodable {
                struct OSDisk: Decodable { let osType: String? }
                let osDisk: OSDisk?
            }
            struct Network: Decodable {
                struct Reference: Decodable {
                    struct Flags: Decodable { let primary: Bool? }
                    let id: String
                    let properties: Flags?
                }
                let networkInterfaces: [Reference]?
            }
            let hardwareProfile: Hardware?
            let storageProfile: Storage?
            let networkProfile: Network?
        }
        let id: String
        let name: String
        let location: String
        let properties: Properties?
    }

    public init(from decoder: any Decoder) throws {
        let raw = try Raw(from: decoder)
        let nics = raw.properties?.networkProfile?.networkInterfaces ?? []
        self.init(
            id: raw.id, name: raw.name, location: raw.location,
            osType: raw.properties?.storageProfile?.osDisk?.osType,
            vmSize: raw.properties?.hardwareProfile?.vmSize,
            networkInterfaceIDs: nics.map(\.id),
            primaryNetworkInterfaceID: nics.first(where: { $0.properties?.primary == true })?.id)
    }
}

public struct AzureNIC: Sendable, Equatable, Decodable {
    public struct IPConfiguration: Sendable, Equatable {
        public let privateIPAddress: String?
        public let subnetID: String?
        public let primary: Bool
    }

    public let id: String
    public let name: String
    public let virtualMachineID: String?
    public let ipConfigurations: [IPConfiguration]

    /// IP privada y subnet de la configuración primaria (o la primera).
    public var primaryConfiguration: IPConfiguration? { ipConfigurations.first(where: \.primary) ?? ipConfigurations.first }
    public var virtualNetworkID: String? { primaryConfiguration?.subnetID.flatMap(ARMResourceID.virtualNetwork(ofSubnet:)) }

    private struct Raw: Decodable {
        struct Reference: Decodable { let id: String }
        struct Properties: Decodable {
            struct IPConfig: Decodable {
                struct Inner: Decodable {
                    let privateIPAddress: String?
                    let subnet: Reference?
                    let primary: Bool?
                }
                let properties: Inner?
            }
            let virtualMachine: Reference?
            let ipConfigurations: [IPConfig]?
        }
        let id: String
        let name: String
        let properties: Properties?
    }

    public init(from decoder: any Decoder) throws {
        let raw = try Raw(from: decoder)
        id = raw.id
        name = raw.name
        virtualMachineID = raw.properties?.virtualMachine?.id
        ipConfigurations = (raw.properties?.ipConfigurations ?? []).map {
            IPConfiguration(privateIPAddress: $0.properties?.privateIPAddress, subnetID: $0.properties?.subnet?.id,
                            primary: $0.properties?.primary ?? false)
        }
    }
}

public struct AzureBastion: Sendable, Equatable, Decodable {
    public let id: String
    public let name: String
    public let location: String
    /// `Developer`, `Basic`, `Standard` o `Premium`.
    public let sku: String
    public let dnsName: String?
    public let enableTunneling: Bool
    public let enableIpConnect: Bool
    public let enablePrivateOnlyBastion: Bool
    public let scaleUnits: Int?
    /// VNets que sirve: la de su `AzureBastionSubnet` o, en Developer,
    /// `properties.virtualNetwork.id`.
    public let virtualNetworkIDs: [String]

    /// Native client (`az network bastion tunnel` y nuestro túnel) exige
    /// Standard/Premium con *native client support* (`enableTunneling`).
    public var supportsNativeClient: Bool {
        ["standard", "premium"].contains(sku.lowercased()) && enableTunneling
    }

    private struct Raw: Decodable {
        struct Reference: Decodable { let id: String }
        struct SKU: Decodable { let name: String? }
        struct Properties: Decodable {
            struct IPConfig: Decodable {
                struct Inner: Decodable { let subnet: Reference? }
                let properties: Inner?
            }
            let dnsName: String?
            let enableTunneling: Bool?
            let enableIpConnect: Bool?
            let enablePrivateOnlyBastion: Bool?
            let scaleUnits: Int?
            let ipConfigurations: [IPConfig]?
            let virtualNetwork: Reference?
        }
        let id: String
        let name: String
        let location: String
        let sku: SKU?
        let properties: Properties?
    }

    public init(from decoder: any Decoder) throws {
        let raw = try Raw(from: decoder)
        id = raw.id
        name = raw.name
        location = raw.location
        sku = raw.sku?.name ?? "Standard"  // default documentado de la API
        dnsName = raw.properties?.dnsName
        enableTunneling = raw.properties?.enableTunneling ?? false
        enableIpConnect = raw.properties?.enableIpConnect ?? false
        enablePrivateOnlyBastion = raw.properties?.enablePrivateOnlyBastion ?? false
        scaleUnits = raw.properties?.scaleUnits
        let fromSubnets = (raw.properties?.ipConfigurations ?? []).compactMap {
            $0.properties?.subnet.flatMap { ARMResourceID.virtualNetwork(ofSubnet: $0.id) }
        }
        virtualNetworkIDs = fromSubnets + [raw.properties?.virtualNetwork?.id].compactMap { $0 }
    }
}
