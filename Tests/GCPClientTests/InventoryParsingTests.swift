import Compression
import Foundation
import Testing

// Prototipo de parseo de inventario de paquetes (GH-??, spec `specs/inventory/`).
// Vive aquí temporalmente (tipos + tests en el mismo archivo) porque esta tarea es
// solo spec + tests: no se tocan `Sources/` existentes. Cuando se implemente la
// llamada de red (`GCPClient.getGuestAttributes`) y el fan-out por zona/proyecto, estos
// tipos SHALL moverse a su propio módulo (ver `specs/inventory/design.md`).

/// Respuesta de `instances.getGuestAttributes`. La API devuelve o bien un único par
/// `variableKey`/`variableValue` (si se pidió una clave exacta) o un árbol
/// `queryValue.items[]` (si se pidió un prefijo como `guestInventory/`).
struct GuestAttributesResponse: Decodable, Equatable {
    struct QueryValue: Decodable, Equatable {
        struct Item: Decodable, Equatable {
            let namespace: String?
            let key: String?
            let value: String?
        }
        let items: [Item]?
    }

    let variableKey: String?
    let variableValue: String?
    let queryValue: QueryValue?
}

struct InventoryPackage: Equatable, Sendable {
    let manager: String
    let name: String
    let version: String?
    let architecture: String?
}

enum GuestAttributeDecodingError: Error, Equatable {
    case notBase64
    case notGzip
    case truncatedHeader
    case decompressionFailed
}

enum InventoryParsingError: Error, Equatable {
    case missingInstalledPackagesKey
    case invalidJSON
}

/// Decodifica el valor `InstalledPackages`/`PackageUpdates` de guest attributes:
/// base64 de un stream `gzip` (RFC 1952) de un documento JSON.
struct GuestAttributeDecoder {
    static func decodeInstalledPackagesPayload(_ base64: String) throws -> Data {
        guard let compressed = Data(base64Encoded: base64) else {
            throw GuestAttributeDecodingError.notBase64
        }
        return try gunzip(compressed)
    }

    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else {
            throw GuestAttributeDecodingError.notGzip
        }
        let flags = bytes[3]
        var offset = 10

        func skipNullTerminated() throws {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count else { throw GuestAttributeDecodingError.truncatedHeader }
            offset += 1
        }

        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 <= bytes.count else { throw GuestAttributeDecodingError.truncatedHeader }
            let xlen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 { try skipNullTerminated() }  // FNAME
        if flags & 0x10 != 0 { try skipNullTerminated() }  // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC

        guard offset + 8 <= bytes.count else { throw GuestAttributeDecodingError.truncatedHeader }
        let trailerStart = bytes.count - 8
        guard offset <= trailerStart else { throw GuestAttributeDecodingError.truncatedHeader }

        let isize = UInt32(bytes[trailerStart + 4]) | (UInt32(bytes[trailerStart + 5]) << 8)
            | (UInt32(bytes[trailerStart + 6]) << 16) | (UInt32(bytes[trailerStart + 7]) << 24)
        let deflateBytes = Array(bytes[offset..<trailerStart])
        var destination = [UInt8](repeating: 0, count: max(Int(isize), 1))
        let decodedCount = compression_decode_buffer(
            &destination, destination.count,
            deflateBytes, deflateBytes.count,
            nil, COMPRESSION_ZLIB)
        guard decodedCount > 0 else { throw GuestAttributeDecodingError.decompressionFailed }
        return Data(destination[0..<decodedCount])
    }
}

/// Aplana el JSON heterogéneo por gestor de paquetes (`apt`/`yum`/`googet`/`wua`/…) a
/// una lista única de `InventoryPackage`.
struct PackageInventoryParser {
    static let knownManagers = [
        "apt", "deb", "yum", "rpm", "zypper", "zypperPatches",
        "cos", "snap", "gem", "pip", "googet", "wua", "qfe",
    ]

    static func parse(json data: Data) throws -> [InventoryPackage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InventoryParsingError.invalidJSON
        }
        var result: [InventoryPackage] = []
        for manager in knownManagers {
            guard let entries = root[manager] as? [[String: Any]] else { continue }
            for entry in entries {
                let name = (entry["name"] as? String)
                    ?? (entry["Title"] as? String)
                    ?? (entry["Caption"] as? String)
                guard let name, !name.isEmpty else { continue }
                result.append(InventoryPackage(
                    manager: manager,
                    name: name,
                    version: entry["version"] as? String,
                    architecture: entry["arch"] as? String))
            }
        }
        return result
    }

    /// Extrae `InstalledPackages` de una `GuestAttributesResponse` (en cualquiera de
    /// las dos formas que devuelve la API), la decodifica y la aplana a paquetes.
    static func packages(from response: GuestAttributesResponse) throws -> [InventoryPackage] {
        let fromTree = response.queryValue?.items?.first {
            $0.namespace == "guestInventory" && $0.key == "InstalledPackages"
        }?.value
        let fromVariable = response.variableKey == "guestInventory/InstalledPackages"
            ? response.variableValue
            : nil
        guard let raw = fromTree ?? fromVariable else {
            throw InventoryParsingError.missingInstalledPackagesKey
        }
        let json = try GuestAttributeDecoder.decodeInstalledPackagesPayload(raw)
        return try parse(json: json)
    }
}

@Suite("Parseo de inventario de paquetes (guest attributes)")
struct InventoryParsingTests {
    // Fixtures generadas con `python3 -c "import gzip,base64,json; …"` a partir del
    // formato documentado de `guestInventory/InstalledPackages` (ver design.md):
    // JSON con claves por gestor (`apt`, `googet`, `wua`, …) → gzip → base64.

    /// {"apt":[{"name":"curl","arch":"amd64","version":"7.81.0-1ubuntu1.15"}],
    ///  "googet":[{"name":"google-compute-engine-metadata-scripts","arch":"x86_64","version":"20230801.00.0@1"}],
    ///  "wua":[{"Title":"Security Update KB1234567","UpdateID":"aaaa-bbbb","KBArticleIDs":["1234567"]}],
    ///  "unknownManager":[{"name":"should-be-ignored","version":"0"}]}
    static let fullPayloadBase64 =
        "H4sIAAAAAAAA/2WPT0/DMAzFv0qVM6mSbusqTmPaZZo4ASc0Ibe1sojUqfKHgaZ9d5JWSDB8cp6d93u+MBgDuy9eL4xgwNSxLjrD7goGrjvlNwx9vczCBzqvLWVtXTayFFzGNlKIspQrdj2mFWWtwhu/rBnknR3GGJAjKU3IBwzQQwDuO6fH4H8TP5v67R+yEtVCNCJhRSk2cuadI8ywZx3MRHvClF+Hr+JlTPZYHLayWixX9Trbzdp+N52Virep8uCwfXBBdybNfDZkP5+OEybSO9kzPQKBQvf3PH+y0fS8Ra4VWYf9TW6Rkl6/AQNDqFBnAQAA"

    /// `{}` → gzip → base64 (sin paquetes).
    static let emptyPayloadBase64 = "H4sIAAAAAAAA/6uuBQBDv6ajAgAAAA=="

    /// Mismo JSON de `fullPayloadBase64` pero sin comprimir (base64 válido, no es gzip).
    static let notGzipBase64 =
        "eyJhcHQiOiBbeyJuYW1lIjogImN1cmwiLCAiYXJjaCI6ICJhbWQ2NCIsICJ2ZXJzaW9uIjogIjcuODEuMC0xdWJ1bnR1MS4xNSJ9XSwgImdvb2dldCI6IFt7Im5hbWUiOiAiZ29vZ2xlLWNvbXB1dGUtZW5naW5lLW1ldGFkYXRhLXNjcmlwdHMiLCAiYXJjaCI6ICJ4ODZfNjQiLCAidmVyc2lvbiI6ICIyMDIzMDgwMS4wMC4wQDEifV0sICJ3dWEiOiBbeyJUaXRsZSI6ICJTZWN1cml0eSBVcGRhdGUgS0IxMjM0NTY3IiwgIlVwZGF0ZUlEIjogImFhYWEtYmJiYiIsICJLQkFydGljbGVJRHMiOiBbIjEyMzQ1NjciXX1dLCAidW5rbm93bk1hbmFnZXIiOiBbeyJuYW1lIjogInNob3VsZC1iZS1pZ25vcmVkIiwgInZlcnNpb24iOiAiMCJ9XX0="

    /// Cabecera `gzip` truncada a 6 bytes (< 10 bytes mínimos de cabecera).
    static let truncatedHeaderBase64 = "H4sIAAAA"

    @Test func decodesKnownManagersAndIgnoresUnknownAndNameless() throws {
        let json = try GuestAttributeDecoder.decodeInstalledPackagesPayload(Self.fullPayloadBase64)
        let packages = try PackageInventoryParser.parse(json: json)

        #expect(packages.count == 3)
        #expect(packages.contains(InventoryPackage(
            manager: "apt", name: "curl", version: "7.81.0-1ubuntu1.15", architecture: "amd64")))
        #expect(packages.contains(InventoryPackage(
            manager: "googet", name: "google-compute-engine-metadata-scripts",
            version: "20230801.00.0@1", architecture: "x86_64")))
        #expect(packages.contains(InventoryPackage(
            manager: "wua", name: "Security Update KB1234567", version: nil, architecture: nil)))
        #expect(!packages.contains { $0.name == "should-be-ignored" })
    }

    @Test func emptyPayloadProducesEmptyList() throws {
        let json = try GuestAttributeDecoder.decodeInstalledPackagesPayload(Self.emptyPayloadBase64)
        let packages = try PackageInventoryParser.parse(json: json)
        #expect(packages.isEmpty)
    }

    @Test func parsesFromQueryValueTreeShape() throws {
        let response = GuestAttributesResponse(
            variableKey: nil, variableValue: nil,
            queryValue: .init(items: [
                .init(namespace: "guestInventory", key: "Hostname", value: "vm-1"),
                .init(namespace: "guestInventory", key: "InstalledPackages", value: Self.fullPayloadBase64),
            ]))
        let packages = try PackageInventoryParser.packages(from: response)
        #expect(packages.count == 3)
    }

    @Test func parsesFromSingleVariableShape() throws {
        let response = GuestAttributesResponse(
            variableKey: "guestInventory/InstalledPackages",
            variableValue: Self.fullPayloadBase64,
            queryValue: nil)
        let packages = try PackageInventoryParser.packages(from: response)
        #expect(packages.count == 3)
    }

    @Test func missingInstalledPackagesKeyThrowsTypedError() {
        let response = GuestAttributesResponse(
            variableKey: nil, variableValue: nil,
            queryValue: .init(items: [
                .init(namespace: "guestInventory", key: "Hostname", value: "vm-1"),
            ]))
        #expect(throws: InventoryParsingError.missingInstalledPackagesKey) {
            try PackageInventoryParser.packages(from: response)
        }
    }

    @Test func invalidBase64ThrowsTypedError() {
        #expect(throws: GuestAttributeDecodingError.notBase64) {
            try GuestAttributeDecoder.decodeInstalledPackagesPayload("not-base64!!! not valid ##")
        }
    }

    @Test func validBase64WithoutGzipMagicThrowsTypedError() {
        #expect(throws: GuestAttributeDecodingError.notGzip) {
            try GuestAttributeDecoder.decodeInstalledPackagesPayload(Self.notGzipBase64)
        }
    }

    @Test func truncatedGzipHeaderThrowsTypedError() {
        #expect(throws: GuestAttributeDecodingError.notGzip) {
            try GuestAttributeDecoder.decodeInstalledPackagesPayload(Self.truncatedHeaderBase64)
        }
    }

    @Test func malformedJsonAfterDecompressionThrowsTypedError() throws {
        let notJson = Data("not json at all".utf8)
        #expect(throws: InventoryParsingError.invalidJSON) {
            try PackageInventoryParser.parse(json: notJson)
        }
    }

    @Test func gzipHeaderWithUnterminatedFNameThrowsTruncatedHeader() {
        // Magic + método deflate + flag FNAME (0x08) + mtime/xfl/os + nombre sin
        // terminador `\0`: pasa el chequeo de longitud mínima (>18) pero el parseo
        // de cabecera se queda sin bytes buscando el fin del nombre.
        var bytes: [UInt8] = [0x1f, 0x8b, 0x08, 0x08, 0, 0, 0, 0, 0, 0]
        bytes.append(contentsOf: Array(repeating: UInt8(ascii: "a"), count: 12))
        let malformed = Data(bytes)
        #expect(throws: GuestAttributeDecodingError.truncatedHeader) {
            try GuestAttributeDecoder.gunzip(malformed)
        }
    }
}
