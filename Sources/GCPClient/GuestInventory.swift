import Compression
import Foundation
import OSLog

/// Respuesta de Compute `instances.getGuestAttributes` para una clave o un prefijo.
public struct GuestAttributesResponse: Decodable, Equatable, Sendable {
    public struct QueryValue: Decodable, Equatable, Sendable {
        public struct Item: Decodable, Equatable, Sendable {
            public let namespace: String?
            public let key: String?
            public let value: String?

            public init(namespace: String?, key: String?, value: String?) {
                self.namespace = namespace
                self.key = key
                self.value = value
            }
        }

        public let items: [Item]?

        public init(items: [Item]?) { self.items = items }
    }

    public let variableKey: String?
    public let variableValue: String?
    public let queryValue: QueryValue?

    public init(variableKey: String?, variableValue: String?, queryValue: QueryValue?) {
        self.variableKey = variableKey
        self.variableValue = variableValue
        self.queryValue = queryValue
    }
}

public struct InventoryPackage: Equatable, Sendable {
    public let manager: String
    public let name: String
    public let version: String?
    public let architecture: String?

    public init(manager: String, name: String, version: String?, architecture: String?) {
        self.manager = manager
        self.name = name
        self.version = version
        self.architecture = architecture
    }
}

public enum GuestAttributeDecodingError: Error, Equatable, Sendable {
    case notBase64
    case notGzip
    case truncatedHeader
    case decompressionFailed
}

public enum InventoryParsingError: Error, Equatable, Sendable {
    case missingInstalledPackagesKey
    case invalidJSON
}

public enum GuestAttributeDecoder {
    public static func decodeInstalledPackagesPayload(_ base64: String) throws -> Data {
        guard let compressed = Data(base64Encoded: base64) else {
            throw GuestAttributeDecodingError.notBase64
        }
        return try gunzip(compressed)
    }

    public static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else { throw GuestAttributeDecodingError.notGzip }
        guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else {
            throw GuestAttributeDecodingError.notGzip
        }

        let flags = bytes[3]
        var offset = 10

        func skipNullTerminated() throws {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count else {
                throw GuestAttributeDecodingError.truncatedHeader
            }
            offset += 1
        }

        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else {
                throw GuestAttributeDecodingError.truncatedHeader
            }
            let length = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2
            guard offset + length <= bytes.count else {
                throw GuestAttributeDecodingError.truncatedHeader
            }
            offset += length
        }
        if flags & 0x08 != 0 { try skipNullTerminated() }
        if flags & 0x10 != 0 { try skipNullTerminated() }
        if flags & 0x02 != 0 {
            guard offset + 2 <= bytes.count else {
                throw GuestAttributeDecodingError.truncatedHeader
            }
            offset += 2
        }

        guard bytes.count >= 18 else { throw GuestAttributeDecodingError.truncatedHeader }
        let trailerStart = bytes.count - 8
        guard offset <= trailerStart else { throw GuestAttributeDecodingError.truncatedHeader }

        let size = UInt32(bytes[trailerStart + 4])
            | (UInt32(bytes[trailerStart + 5]) << 8)
            | (UInt32(bytes[trailerStart + 6]) << 16)
            | (UInt32(bytes[trailerStart + 7]) << 24)
        guard size > 0 else { return Data() }

        let compressed = Array(bytes[offset..<trailerStart])
        var destination = [UInt8](repeating: 0, count: Int(size))
        let decoded = compression_decode_buffer(
            &destination, destination.count, compressed, compressed.count,
            nil, COMPRESSION_ZLIB)
        guard decoded == destination.count else {
            throw GuestAttributeDecodingError.decompressionFailed
        }
        return Data(destination)
    }
}

public enum PackageInventoryParser {
    public static let knownManagers = [
        "apt", "deb", "yum", "rpm", "zypper", "zypperPatches",
        "cos", "snap", "gem", "pip", "googet", "wua", "qfe",
    ]

    public static func parse(json data: Data) throws -> [InventoryPackage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InventoryParsingError.invalidJSON
        }

        return knownManagers.flatMap { manager -> [InventoryPackage] in
            guard let entries = root[manager] as? [[String: Any]] else { return [] }
            return entries.compactMap { entry in
                let name = (entry["name"] as? String)
                    ?? (entry["Title"] as? String)
                    ?? (entry["Caption"] as? String)
                guard let name, !name.isEmpty else { return nil }
                return InventoryPackage(
                    manager: manager,
                    name: name,
                    version: entry["version"] as? String,
                    architecture: entry["arch"] as? String)
            }
        }
    }

    public static func packages(from response: GuestAttributesResponse) throws -> [InventoryPackage] {
        let treeValue = response.queryValue?.items?.first {
            $0.namespace == "guestInventory" && $0.key == "InstalledPackages"
        }?.value
        let variableValue = response.variableKey == "guestInventory/InstalledPackages"
            ? response.variableValue : nil
        guard let payload = treeValue ?? variableValue else {
            throw InventoryParsingError.missingInstalledPackagesKey
        }
        return try parse(json: GuestAttributeDecoder.decodeInstalledPackagesPayload(payload))
    }
}

/// Resultado por VM. `packages == nil` significa que el agente no publicó datos
/// o que esa VM falló; el resto del fan-out se conserva.
public struct InstancePackageInventory: Equatable, Sendable {
    public let project: String
    public let zone: String
    public let instance: String
    public let packages: [InventoryPackage]?

    public init(project: String, zone: String, instance: String, packages: [InventoryPackage]?) {
        self.project = project
        self.zone = zone
        self.instance = instance
        self.packages = packages
    }
}

extension GCPClient {
    private static let inventoryLog = Logger(
        subsystem: "com.iapdesktop.mac", category: "guest-inventory")

    public func getGuestAttributes(
        project: String, zone: String, instance: String,
        queryPath: String = "guestInventory/"
    ) async throws -> GuestAttributesResponse {
        let base = "https://compute.googleapis.com/compute/v1/projects/\(inventoryPath(project))"
            + "/zones/\(inventoryPath(zone))/instances/\(inventoryPath(instance))/getGuestAttributes"
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "queryPath", value: queryPath)]
        return try await get(components.url!)
    }

    /// `nil` es inventario no disponible; payload corrupto y errores HTTP siguen
    /// siendo errores para una consulta directa de instancia.
    public func packageInventory(
        project: String, zone: String, instance: String
    ) async throws -> [InventoryPackage]? {
        let started = ContinuousClock.now
        let response = try await getGuestAttributes(
            project: project, zone: zone, instance: instance)
        let packages: [InventoryPackage]
        do {
            packages = try PackageInventoryParser.packages(from: response)
        } catch InventoryParsingError.missingInstalledPackagesKey {
            Self.inventoryLog.notice("inventory unavailable duration_ms=\(started.duration(to: .now).milliseconds, privacy: .public)")
            return nil
        }
        let elapsed = started.duration(to: .now).milliseconds
        Self.inventoryLog.notice("inventory loaded packages=\(packages.count, privacy: .public) duration_ms=\(elapsed, privacy: .public)")
        for (manager, count) in Dictionary(grouping: packages, by: \.manager).mapValues(\.count) {
            Self.inventoryLog.debug("inventory manager=\(manager, privacy: .public) packages=\(count, privacy: .public)")
        }
        return packages
    }

    public func collectZonePackageInventory(
        project: String, zone: String, maximumConcurrentRequests: Int = 8
    ) async throws -> [InstancePackageInventory] {
        let instances = try await aggregatedListInstances(project: project)
            .filter { $0.zone == zone && $0.operatingSystem != .windows }
        return await collectPackageInventory(
            project: project, instances: instances,
            maximumConcurrentRequests: maximumConcurrentRequests)
    }

    public func collectProjectPackageInventory(
        project: String, maximumConcurrentRequests: Int = 8
    ) async throws -> [InstancePackageInventory] {
        let instances = try await aggregatedListInstances(project: project)
            .filter { $0.operatingSystem != .windows }
        return await collectPackageInventory(
            project: project, instances: instances,
            maximumConcurrentRequests: maximumConcurrentRequests)
    }

    private func collectPackageInventory(
        project: String, instances: [ComputeInstance], maximumConcurrentRequests: Int
    ) async -> [InstancePackageInventory] {
        let limit = max(1, min(maximumConcurrentRequests, 8))
        return await withTaskGroup(of: (Int, InstancePackageInventory).self) { group in
            var iterator = instances.enumerated().makeIterator()

            func submit(_ indexed: (offset: Int, element: ComputeInstance)) {
                group.addTask { [self] in
                    let instance = indexed.element
                    let packages = try? await packageInventory(
                        project: project, zone: instance.zone, instance: instance.name)
                    return (indexed.offset, InstancePackageInventory(
                        project: project, zone: instance.zone, instance: instance.name,
                        packages: packages ?? nil))
                }
            }

            for _ in 0..<min(limit, instances.count) {
                if let next = iterator.next() { submit(next) }
            }

            var results: [(Int, InstancePackageInventory)] = []
            while let result = await group.next() {
                results.append(result)
                if let next = iterator.next() { submit(next) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

private func inventoryPath(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private extension Duration {
    var milliseconds: Int64 {
        let components = self.components
        return components.seconds * 1_000 + Int64(components.attoseconds / 1_000_000_000_000_000)
    }
}
