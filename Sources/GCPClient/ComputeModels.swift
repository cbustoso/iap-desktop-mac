import Foundation

public struct GCPProject: Decodable, Equatable, Sendable {
    public let projectId: String
    public let displayName: String

    private enum CodingKeys: String, CodingKey {
        case projectId
        case displayName
        case name
    }

    public init(projectId: String, displayName: String) {
        self.projectId = projectId
        self.displayName = displayName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try container.decode(String.self, forKey: .projectId)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? projectId
    }
}

public enum InstancePowerState: String, Decodable, Equatable, Sendable {
    case running
    case stopped
    case unknown

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self).uppercased() {
        case "RUNNING": self = .running
        case "STOPPED", "TERMINATED", "SUSPENDED": self = .stopped
        default: self = .unknown
        }
    }
}

public enum OperatingSystem: String, Equatable, Sendable {
    case linux
    case windows
}

public struct ComputeDisk: Decodable, Equatable, Sendable {
    public let licenses: [String]

    public init(licenses: [String]) {
        self.licenses = licenses
    }

    private enum CodingKeys: CodingKey { case licenses }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        licenses = try container.decodeIfPresent([String].self, forKey: .licenses) ?? []
    }
}

public struct GuestOSFeature: Decodable, Equatable, Sendable {
    public let type: String

    public init(type: String) {
        self.type = type
    }
}

public struct ComputeInstance: Decodable, Equatable, Sendable {
    public let name: String
    public let zone: String
    public let status: InstancePowerState
    public let disks: [ComputeDisk]?
    public let guestOsFeatures: [GuestOSFeature]
    public let operatingSystem: OperatingSystem

    private enum CodingKeys: CodingKey {
        case name
        case zone
        case status
        case disks
        case guestOsFeatures
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let zonePath = try container.decode(String.self, forKey: .zone)
        zone = zonePath.split(separator: "/").last.map(String.init) ?? zonePath
        status = try container.decode(InstancePowerState.self, forKey: .status)
        disks = try container.decodeIfPresent([ComputeDisk].self, forKey: .disks)
        guestOsFeatures = try container.decodeIfPresent(
            [GuestOSFeature].self, forKey: .guestOsFeatures) ?? []
        operatingSystem = TraitDetector.detect(
            disks: disks ?? [], guestOsFeatures: guestOsFeatures)
    }
}

public enum TraitDetector {
    public static func detect(
        disks: [ComputeDisk], guestOsFeatures: [GuestOSFeature]
    ) -> OperatingSystem {
        let hasWindowsLicense = disks
            .flatMap(\.licenses)
            .contains { $0.localizedCaseInsensitiveContains("windows-cloud/global/licenses/") }
        let hasWindowsFeature = guestOsFeatures.contains {
            $0.type.localizedCaseInsensitiveContains("windows")
        }
        return hasWindowsLicense || hasWindowsFeature ? .windows : .linux
    }
}

struct ProjectListResponse: Decodable, Sendable {
    let projects: [GCPProject]?
    let nextPageToken: String?
}

struct AggregatedInstanceListResponse: Decodable, Sendable {
    let items: [String: ScopedInstanceList]?
}

struct ScopedInstanceList: Decodable, Sendable {
    let instances: [ComputeInstance]?
    let warning: APIWarning?
}

struct APIWarning: Decodable, Sendable {
    let code: String?
    let message: String?
}
