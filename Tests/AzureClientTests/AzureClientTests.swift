// GH-90: AzureARMClient (paginación, api-version, throttling, errores) y
// AzureDiscovery (árbol con fallos por nodo y emparejamiento VM ↔ Bastion).
// Todo con un URLProtocol stub: ninguna llamada sale a management.azure.com.
import Foundation
import Testing
@testable import AzureClient

private struct Request: Sendable {
    let path: String
    let query: [String: String]
    let host: String
    let authorization: String?
}

/// Stub ARM: un handler por `URLSession` (cabecera `X-Stub-ID`).
private final class ARMStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (Request) -> (Int, [String: String], String)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func session(_ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ARMStub.self]
        configuration.httpAdditionalHeaders = ["X-Stub-ID": id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let handler = request.value(forHTTPHeaderField: "X-Stub-ID").flatMap { id in Self.lock.withLock { Self.handlers[id] } }
        let seen = Request(path: url.path, query: query, host: url.host ?? "", authorization: request.value(forHTTPHeaderField: "Authorization"))
        let (status, headers, body) = handler?(seen) ?? (500, [:], "{}")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class Log<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

/// Peticiones en vuelo simultáneas (máximo observado).
private final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
    func leave() { lock.withLock { current -= 1 } }
    var maximum: Int { lock.withLock { peak } }
}

private let home = "aaaaaaaa-0000-0000-0000-000000000001"
private let guest = "bbbbbbbb-0000-0000-0000-000000000002"
private let subA = "00000000-0000-0000-0000-00000000000a"
private let subB = "00000000-0000-0000-0000-00000000000b"
private let subOff = "00000000-0000-0000-0000-0000000000ff"

private func client(_ session: URLSession, sleeps: Log<Duration>? = nil, token: AzureARMClient.TokenProvider? = nil) -> AzureARMClient {
    AzureARMClient(session: session, sleep: { sleeps?.add($0) }, token: token ?? { "token-\($0)" })
}

private func page(_ items: [String], next: String? = nil) -> String {
    #"{"value":[\#(items.joined(separator: ","))]\#(next.map { #","nextLink":"\#($0)""# } ?? "")}"#
}

private func ok(_ body: String) -> (Int, [String: String], String) { (200, [:], body) }

// MARK: - Fixtures (formas de los ejemplos de la REST reference)

private func rgJSON(_ sub: String, _ name: String) -> String {
    #"{"id":"/subscriptions/\#(sub)/resourceGroups/\#(name)","name":"\#(name)","location":"westeurope","properties":{"provisioningState":"Succeeded"}}"#
}

private func vmJSON(_ sub: String, rg: String, _ name: String, nics: [(String, Bool?)] = [], os: String = "Linux") -> String {
    let refs = nics.map { id, primary in
        #"{"id":"\#(id)"\#(primary.map { #","properties":{"primary":\#($0)}"# } ?? "")}"#
    }
    return #"""
    {"id":"/subscriptions/\#(sub)/resourceGroups/\#(rg)/providers/Microsoft.Compute/virtualMachines/\#(name)","name":"\#(name)","location":"westeurope",
     "properties":{"hardwareProfile":{"vmSize":"Standard_B2s"},"storageProfile":{"osDisk":{"osType":"\#(os)","name":"disk"}},
     "networkProfile":{"networkInterfaces":[\#(refs.joined(separator: ","))]}}}
    """#
}

private func nicID(_ sub: String, rg: String, _ name: String) -> String {
    "/subscriptions/\(sub)/resourceGroups/\(rg)/providers/Microsoft.Network/networkInterfaces/\(name)"
}

private func vnetID(_ sub: String, rg: String, _ name: String) -> String {
    "/subscriptions/\(sub)/resourceGroups/\(rg)/providers/Microsoft.Network/virtualNetworks/\(name)"
}

private func nicJSON(_ id: String, vnet: String, ip: String, vm: String? = nil) -> String {
    #"""
    {"id":"\#(id)","name":"nic","properties":{\#(vm.map { #""virtualMachine":{"id":"\#($0)"},"# } ?? "")
     "ipConfigurations":[{"name":"ipconfig1","properties":{"privateIPAddress":"\#(ip)","privateIPAllocationMethod":"Dynamic","primary":true,
     "subnet":{"id":"\#(vnet)/subnets/default"}}}]}}
    """#
}

private func bastionJSON(_ sub: String, _ name: String, vnet: String, sku: String = "Standard", tunneling: Bool = true) -> String {
    #"""
    {"id":"/subscriptions/\#(sub)/resourceGroups/hub/providers/Microsoft.Network/bastionHosts/\#(name)","name":"\#(name)","location":"West US",
     "sku":{"name":"\#(sku)"},"properties":{"dnsName":"bst-1.bastion.azure.com","enableTunneling":\#(tunneling),"enableIpConnect":false,
     "enablePrivateOnlyBastion":false,"scaleUnits":2,"ipConfigurations":[{"name":"c","properties":{"subnet":{"id":"\#(vnet)/subnets/AzureBastionSubnet"}}}]}}
    """#
}

@Suite("AzureARMClient (GH-90)")
struct AzureARMClientTests {
    @Test func followsThreePagesWithTheTenantTokenAndExactNextLink() async throws {
        let seen = Log<Request>()
        let session = ARMStub.session { request in
            seen.add(request)
            switch request.query["$skiptoken"] {
            case nil: return ok(page([rgJSON(subA, "rg-1")], next: "https://management.azure.com/subscriptions/\(subA)/resourcegroups?api-version=2024-11-01&$skiptoken=p2"))
            case "p2": return ok(page([rgJSON(subA, "rg-2"), rgJSON(subA, "rg-3")], next: "https://management.azure.com/subscriptions/\(subA)/resourcegroups?api-version=2024-11-01&$skiptoken=p3"))
            default: return ok(page([rgJSON(subA, "rg-4")], next: ""))
            }
        }
        let groups = try await client(session).resourceGroups(subscriptionID: subA, tenantID: guest)
        #expect(groups.map(\.name) == ["rg-1", "rg-2", "rg-3", "rg-4"])
        #expect(seen.all.count == 3)
        #expect(seen.all.allSatisfy { $0.authorization == "Bearer token-\(guest)" && $0.query["api-version"] == "2024-11-01" })
        #expect(seen.all.map { $0.query["$skiptoken"] } == [nil, "p2", "p3"])
    }

    @Test func nextLinkToAnotherHostNeverReceivesTheBearer() async throws {
        let seen = Log<Request>()
        let session = ARMStub.session { request in
            seen.add(request)
            return ok(page([], next: "https://evil.example/subscriptions?api-version=2022-12-01"))
        }
        await #expect(throws: AzureARMError.invalidNextLink) { try await client(session).subscriptions(tenantID: home) }
        #expect(seen.all.map(\.host) == ["management.azure.com"])
    }

    @Test func aNextLinkThatRepeatsStopsInsteadOfLooping() async throws {
        let link = "https://management.azure.com/subscriptions?api-version=2022-12-01&$skiptoken=same"
        let session = ARMStub.session { _ in ok(page([], next: link)) }
        await #expect(throws: AzureARMError.invalidNextLink) { try await client(session).subscriptions(tenantID: home) }
    }

    @Test func throttlingHonoursRetryAfterWithABoundedBackoff() async throws {
        let attempts = Log<Int>()
        let sleeps = Log<Duration>()
        let session = ARMStub.session { _ in
            attempts.add(1)
            switch attempts.all.count {
            case 1: return (429, ["Retry-After": "7"], #"{"error":{"code":"TooManyRequests"}}"#)
            case 2: return (429, ["Retry-After": "3600"], "{}")
            case 3: return (503, [:], "{}")
            default: return ok(page([#"{"tenantId":"\#(home)","displayName":"Contoso","tenantCategory":"Home"}"#]))
            }
        }
        let tenants = try await client(session, sleeps: sleeps).tenants(homeTenantID: home)
        #expect(tenants == [AzureTenant(tenantID: home, displayName: "Contoso", tenantCategory: "Home")])
        #expect(sleeps.all == [.seconds(7), .seconds(30), .seconds(4)])  // tope 30 s; sin cabecera, 2^intento
    }

    @Test func throttlingGivesUpAfterTheRetries() async throws {
        let sleeps = Log<Duration>()
        let session = ARMStub.session { _ in (429, [:], "{}") }
        await #expect(throws: AzureARMError.throttled(status: 429)) {
            try await client(session, sleeps: sleeps).subscriptions(tenantID: home)
        }
        #expect(sleeps.all == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test func armErrorsCarryCodeAndMessage() async throws {
        let session = ARMStub.session { _ in
            (403, [:], #"{"error":{"code":"AuthorizationFailed","message":"does not have authorization to perform action"}}"#)
        }
        await #expect(throws: AzureARMError.http(status: 403, code: "AuthorizationFailed", message: "does not have authorization to perform action")) {
            try await client(session).virtualMachines(subscriptionID: subA, tenantID: home)
        }
        let garbage = ARMStub.session { _ in ok("<html>") }
        await #expect(throws: AzureARMError.malformedResponse) { try await client(garbage).subscriptions(tenantID: home) }
    }

    @Test func pathsAndAPIVersions() async throws {
        let seen = Log<Request>()
        let session = ARMStub.session { request in
            seen.add(request)
            return request.path.contains("bastionHosts/") ? ok(bastionJSON(subA, "b1", vnet: vnetID(subA, rg: "hub", "v"))) : ok(page([]))
        }
        let arm = client(session)
        _ = try await arm.tenants(homeTenantID: home)
        _ = try await arm.subscriptions(tenantID: home)
        _ = try await arm.resourceGroups(subscriptionID: subA, tenantID: home)
        _ = try await arm.virtualMachines(subscriptionID: subA, tenantID: home)
        _ = try await arm.networkInterfaces(subscriptionID: subA, tenantID: home)
        _ = try await arm.bastionHosts(subscriptionID: subA, tenantID: home)
        _ = try await arm.bastionHost(id: "/subscriptions/\(subA)/resourceGroups/hub/providers/Microsoft.Network/bastionHosts/b1", tenantID: home)
        #expect(seen.all.map { "\($0.path)?\($0.query["api-version"] ?? "")" } == [
            "/tenants?2022-12-01",
            "/subscriptions?2022-12-01",
            "/subscriptions/\(subA)/resourcegroups?2024-11-01",
            "/subscriptions/\(subA)/providers/Microsoft.Compute/virtualMachines?2026-04-01",
            "/subscriptions/\(subA)/providers/Microsoft.Network/networkInterfaces?2026-01-01",
            "/subscriptions/\(subA)/providers/Microsoft.Network/bastionHosts?2026-01-01",
            "/subscriptions/\(subA)/resourceGroups/hub/providers/Microsoft.Network/bastionHosts/b1?2026-01-01",
        ])
    }

    @Test func malformedIDsNeverReachTheNetwork() async throws {
        let seen = Log<Request>()
        let arm = client(ARMStub.session { seen.add($0); return ok(page([])) })
        await #expect(throws: AzureARMError.invalidResourceID) { try await arm.resourceGroups(subscriptionID: "../tenants", tenantID: home) }
        for bad in ["/subscriptions/x/../../tenants", "https://evil.example/x", "/subscriptions/x?api-version=1", "/providers/x"] {
            await #expect(throws: AzureARMError.invalidResourceID) { try await arm.bastionHost(id: bad, tenantID: home) }
        }
        #expect(seen.all.isEmpty)
    }

    @Test func tokenFailuresPropagateWithoutARequest() async throws {
        struct ConsentRequired: Error {}
        let seen = Log<Request>()
        let arm = client(ARMStub.session { seen.add($0); return ok(page([])) }, token: { _ in throw ConsentRequired() })
        await #expect(throws: ConsentRequired.self) { try await arm.subscriptions(tenantID: guest) }
        #expect(seen.all.isEmpty)
    }
}

@Suite("Azure: modelos ARM (GH-90)")
struct AzureModelTests {
    @Test func bastionSkusAndVirtualNetworks() throws {
        let developer = #"""
        {"id":"/subscriptions/s/resourceGroups/rg2/providers/Microsoft.Network/bastionHosts/dev","name":"dev","location":"West US",
         "sku":{"name":"Developer"},"properties":{"dnsName":"omnibrain.uswest.bastionglobal.azure.com","ipConfigurations":[],
         "virtualNetwork":{"id":"/subscriptions/s/resourceGroups/rg2/providers/Microsoft.Network/virtualNetworks/vnet2"}}}
        """#
        let dev = try JSONDecoder().decode(AzureBastion.self, from: Data(developer.utf8))
        #expect(dev.virtualNetworkIDs == ["/subscriptions/s/resourceGroups/rg2/providers/Microsoft.Network/virtualNetworks/vnet2"])
        #expect(!dev.supportsNativeClient)
        let standard = try JSONDecoder().decode(AzureBastion.self, from: Data(bastionJSON(subA, "b", vnet: vnetID(subA, rg: "hub", "v")).utf8))
        #expect(standard.virtualNetworkIDs == [vnetID(subA, rg: "hub", "v")])
        #expect(standard.supportsNativeClient)
        let basic = try JSONDecoder().decode(AzureBastion.self, from: Data(bastionJSON(subA, "b", vnet: "v/x", sku: "Basic").utf8))
        #expect(!basic.supportsNativeClient)
    }

    @Test func vmPicksThePrimaryNICAndOSType() throws {
        let json = vmJSON(subA, rg: "RG-Web", "web-1", nics: [(nicID(subA, rg: "rg-web", "a"), false), (nicID(subA, rg: "rg-web", "b"), true)], os: "Windows")
        let vm = try JSONDecoder().decode(AzureVM.self, from: Data(json.utf8))
        #expect(vm.primaryNetworkInterfaceID == nicID(subA, rg: "rg-web", "b"))
        #expect(vm.osType == "Windows")
        #expect(vm.vmSize == "Standard_B2s")
        #expect(vm.resourceGroup == "RG-Web")
        let single = try JSONDecoder().decode(AzureVM.self, from: Data(vmJSON(subA, rg: "r", "x", nics: [("n1", nil)]).utf8))
        #expect(single.primaryNetworkInterfaceID == "n1")
    }

    @Test func resourceIDHelpers() {
        #expect(ARMResourceID.virtualNetwork(ofSubnet: "/subscriptions/s/resourceGroups/r/providers/Microsoft.Network/virtualNetworks/v/Subnets/default")
            == "/subscriptions/s/resourceGroups/r/providers/Microsoft.Network/virtualNetworks/v")
        #expect(ARMResourceID.virtualNetwork(ofSubnet: "nope") == nil)
        #expect(ARMResourceID.resourceGroup(of: "/subscriptions/s/resourcegroups/My-RG/providers/x") == "My-RG")
    }
}

@Suite("AzureDiscovery (GH-90)")
struct AzureDiscoveryTests {
    /// Dos tenants: el de origen con dos suscripciones (una deshabilitada) y
    /// una tercera vista también desde el guest (Lighthouse); el guest sin
    /// consentimiento para listar sus propias suscripciones no rompe nada.
    private static func world(failGuestToken: Bool = false, nicsFail: Bool = false, bastionsFail: Bool = false,
                              subBVMsFail: Bool = false, gauge: Gauge? = nil, seen: Log<Request>? = nil) -> AzureARMClient {
        let web = vnetID(subA, rg: "net", "vnet-web")
        let data = vnetID(subA, rg: "net", "vnet-data")
        let session = ARMStub.session { request in
            seen?.add(request)
            let path = request.path
            switch path {
            case "/tenants":
                return ok(page([#"{"tenantId":"\#(guest)","displayName":"Fabrikam","tenantCategory":"Home"}"#,
                                #"{"tenantId":"\#(home)","displayName":"Contoso","tenantCategory":"Home"}"#]))
            case "/subscriptions" where request.authorization == "Bearer token-\(home)":
                return ok(page([
                    #"{"subscriptionId":"\#(subA)","tenantId":"\#(home)","displayName":"Prod","state":"Enabled"}"#,
                    #"{"subscriptionId":"\#(subOff)","tenantId":"\#(home)","displayName":"Old","state":"Disabled"}"#,
                    #"{"subscriptionId":"\#(subB)","tenantId":"\#(guest)","displayName":"Partner","state":"Warned"}"#,
                ]))
            case "/subscriptions":
                return ok(page([#"{"subscriptionId":"\#(subB)","tenantId":"\#(guest)","displayName":"Partner","state":"Enabled"}"#]))
            default: break
            }
            if path.hasSuffix("/resourcegroups") {
                gauge?.enter()
                Thread.sleep(forTimeInterval: 0.05)
                gauge?.leave()
            }
            if path.hasPrefix("/subscriptions/\(subB)") {
                if subBVMsFail, path.hasSuffix("virtualMachines") { return (403, [:], #"{"error":{"code":"AuthorizationFailed"}}"#) }
                return ok(page(path.hasSuffix("/resourcegroups") ? [rgJSON(subB, "partner-rg")] : []))
            }
            if path.hasPrefix("/subscriptions/\(subOff)") { return (500, [:], "{}") }  // nunca debe pedirse
            switch path {
            case "/subscriptions/\(subA)/resourcegroups":
                return ok(page([rgJSON(subA, "rg-web"), rgJSON(subA, "net"), rgJSON(subA, "rg-data")]))
            case "/subscriptions/\(subA)/providers/Microsoft.Compute/virtualMachines" where request.query["$skiptoken"] == "2":
                return ok(page([vmJSON(subA, rg: "rg-new", "late-1", nics: [(nicID(subA, rg: "rg-new", "gone"), nil)])]))
            case "/subscriptions/\(subA)/providers/Microsoft.Compute/virtualMachines":
                return ok(page([
                    vmJSON(subA, rg: "RG-WEB", "web-1", nics: [(nicID(subA, rg: "rg-web", "web-1-nic"), true)]),
                    vmJSON(subA, rg: "rg-web", "orphan", nics: []),
                    vmJSON(subA, rg: "rg-data", "db-1", nics: [(nicID(subA, rg: "rg-data", "db-1-nic"), nil)], os: "Windows"),
                ], next: "https://management.azure.com/subscriptions/\(subA)/providers/Microsoft.Compute/virtualMachines?api-version=2026-04-01&$skiptoken=2"))
            case "/subscriptions/\(subA)/providers/Microsoft.Network/networkInterfaces":
                if nicsFail { return (403, [:], "{}") }
                return ok(page([
                    // ID con otra capitalización: ARM no distingue mayúsculas.
                    nicJSON(nicID(subA, rg: "RG-WEB", "WEB-1-NIC"), vnet: web, ip: "10.0.1.4"),
                    nicJSON(nicID(subA, rg: "rg-data", "db-1-nic"), vnet: data, ip: "10.1.0.4"),
                ]))
            case "/subscriptions/\(subA)/providers/Microsoft.Network/bastionHosts":
                if bastionsFail { return (403, [:], "{}") }
                return ok(page([
                    bastionJSON(subA, "basic-web", vnet: web, sku: "Basic", tunneling: false),
                    bastionJSON(subA, "std-web", vnet: web),
                ]))
            default:
                return (404, [:], #"{"error":{"code":"NotFound"}}"#)
            }
        }
        return AzureARMClient(session: session, sleep: { _ in }) { tenant in
            struct ConsentRequired: Error {}
            if failGuestToken, tenant == guest { throw ConsentRequired() }
            return "token-\(tenant)"
        }
    }

    @Test func buildsTheTreeWithABastionOrAReasonForEveryVM() async throws {
        let seen = Log<Request>()
        let inventory = await AzureDiscovery(client: Self.world(seen: seen)).discover(homeTenantID: home)
        #expect(inventory.tenantListFailure == nil)
        #expect(inventory.tenants.map(\.tenant.tenantID) == [guest, home])
        #expect(inventory.tenants.allSatisfy { $0.failure == nil })

        let contoso = try #require(inventory.tenants.last)
        // Disabled fuera; Partner (de guest) se carga con el tenant dueño, no aquí.
        #expect(contoso.subscriptions.map(\.subscription.subscriptionID) == [subA])
        #expect(!seen.all.contains { $0.path.hasPrefix("/subscriptions/\(subOff)") })
        let prod = try #require(contoso.subscriptions.first)
        #expect(prod.failure == nil)
        #expect(prod.accessTenantID == home)
        #expect(prod.resourceGroups.map(\.name) == ["net", "rg-data", "rg-new", "rg-web"])
        #expect(prod.resourceGroups.first { $0.name == "rg-new" }?.location == nil)  // RG que el listado no trajo

        let vms = Dictionary(uniqueKeysWithValues: prod.resourceGroups.flatMap(\.virtualMachines).map { ($0.vm.name, $0) })
        #expect(vms.count == 4)  // incluye la segunda página (sin duplicar)
        guard case .sameVirtualNetwork(let bastion) = vms["web-1"]?.bastion else {
            Issue.record("web-1 sin Bastion: \(String(describing: vms["web-1"]?.bastion))")
            return
        }
        #expect(bastion.name == "std-web")  // preferido el que soporta native client
        #expect(vms["web-1"]?.privateIPAddress == "10.0.1.4")
        #expect(vms["orphan"]?.bastion == .noNetworkInterface)
        #expect(vms["db-1"]?.bastion == .noBastionInVirtualNetwork(virtualNetworkID: vnetID(subA, rg: "net", "vnet-data")))
        #expect(vms["late-1"]?.bastion == .networkInterfaceNotVisible)

        let fabrikam = try #require(inventory.tenants.first)
        #expect(fabrikam.subscriptions.map(\.subscription.subscriptionID) == [subB])
        #expect(fabrikam.subscriptions.first?.accessTenantID == guest)
        // Cada suscripción con el token de su tenant.
        #expect(seen.all.filter { $0.path.hasPrefix("/subscriptions/\(subB)") }.allSatisfy { $0.authorization == "Bearer token-\(guest)" })
        #expect(seen.all.filter { $0.path.hasPrefix("/subscriptions/\(subA)") }.allSatisfy { $0.authorization == "Bearer token-\(home)" })
    }

    @Test func failuresStayInTheirNode() async throws {
        let inventory = await AzureDiscovery(client: Self.world(failGuestToken: true)).discover(homeTenantID: home)
        let fabrikam = try #require(inventory.tenants.first { $0.tenant.tenantID == guest })
        #expect(fabrikam.failure != nil)
        // Partner sigue visible desde el tenant de origen (delegada) y se carga con ese token.
        let contoso = try #require(inventory.tenants.first { $0.tenant.tenantID == home })
        #expect(contoso.subscriptions.map(\.subscription.subscriptionID).sorted() == [subA, subB])
        #expect(contoso.subscriptions.first { $0.subscription.subscriptionID == subB }?.accessTenantID == home)

        let broken = await AzureDiscovery(client: Self.world(subBVMsFail: true)).discover(homeTenantID: home)
        let partner = try #require(broken.tenants.flatMap(\.subscriptions).first { $0.subscription.subscriptionID == subB })
        #expect(partner.failure as? AzureARMError == .http(status: 403, code: "AuthorizationFailed", message: nil))
        #expect(partner.resourceGroups.isEmpty)
        #expect(broken.tenants.flatMap(\.subscriptions).first { $0.subscription.subscriptionID == subA }?.failure == nil)
    }

    @Test func unreadableNICsOrBastionsDegradePerVM() async throws {
        for (nicsFail, bastionsFail, expected) in [(true, false, BastionAssociation.networkInterfaceNotVisible), (false, true, .bastionsNotVisible)] {
            let inventory = await AzureDiscovery(client: Self.world(nicsFail: nicsFail, bastionsFail: bastionsFail)).discover(homeTenantID: home)
            let prod = try #require(inventory.tenants.flatMap(\.subscriptions).first { $0.subscription.subscriptionID == subA })
            #expect(prod.failure == nil)
            #expect(prod.resourceGroups.flatMap(\.virtualMachines).first { $0.vm.name == "web-1" }?.bastion == expected)
        }
    }

    @Test func tenantListFailureFallsBackToTheHomeTenant() async throws {
        let session = ARMStub.session { request in
            request.path == "/tenants" ? (500, [:], "{}") : ok(page([]))
        }
        let inventory = await AzureDiscovery(client: client(session)).discover(homeTenantID: home)
        #expect(inventory.tenantListFailure != nil)
        #expect(inventory.tenants.map(\.tenant.tenantID) == [home])
    }

    @Test func atMostFourSubscriptionsLoadAtOnce() async throws {
        let gauge = Gauge()
        let subs = (1...10).map { String(format: "00000000-0000-0000-0000-%012d", $0) }
        let session = ARMStub.session { request in
            switch request.path {
            case "/tenants": return ok(page([]))
            case "/subscriptions":
                return ok(page(subs.map { #"{"subscriptionId":"\#($0)","tenantId":"\#(home)","displayName":"S\#($0.suffix(2))","state":"Enabled"}"# }))
            default:
                if request.path.hasSuffix("/resourcegroups") {
                    gauge.enter()
                    Thread.sleep(forTimeInterval: 0.05)
                    gauge.leave()
                }
                return ok(page([]))
            }
        }
        let inventory = await AzureDiscovery(client: client(session), maxConcurrentSubscriptions: 4).discover(homeTenantID: home)
        #expect(inventory.tenants.first?.subscriptions.count == 10)
        #expect(gauge.maximum <= 4)
        #expect(gauge.maximum >= 1)
    }
}
