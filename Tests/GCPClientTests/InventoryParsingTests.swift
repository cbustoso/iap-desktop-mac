import Foundation
import Testing
@testable import GCPClient

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
