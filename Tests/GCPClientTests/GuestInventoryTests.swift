import Foundation
import Testing
@testable import GCPClient

private final class InventoryStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        DispatchQueue.global().async { [self] in
            let (status, body) = Self.handler?(request) ?? (500, Data("{}".utf8))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximumValue = 0
    private var requestedInstancesValue: [String] = []

    var maximum: Int { lock.withLock { maximumValue } }
    var requestedInstances: [String] { lock.withLock { requestedInstancesValue } }

    func begin(instance: String) {
        lock.withLock {
            active += 1
            maximumValue = max(maximumValue, active)
            requestedInstancesValue.append(instance)
        }
    }

    func end() { lock.withLock { active -= 1 } }
}

private let inventoryPayload =
    "H4sIAAAAAAAA/2WPT0/DMAzFv0qVM6mSbusqTmPaZZo4ASc0Ibe1sojUqfKHgaZ9d5JWSDB8cp6d93u+MBgDuy9eL4xgwNSxLjrD7goGrjvlNwx9vczCBzqvLWVtXTayFFzGNlKIspQrdj2mFWWtwhu/rBnknR3GGJAjKU3IBwzQQwDuO6fH4H8TP5v67R+yEtVCNCJhRSk2cuadI8ywZx3MRHvClF+Hr+JlTPZYHLayWixX9Trbzdp+N52Virep8uCwfXBBdybNfDZkP5+OEybSO9kzPQKBQvf3PH+y0fS8Ra4VWYf9TW6Rkl6/AQNDqFBnAQAA"

private func inventoryClient(_ handler: @escaping InventoryStubProtocol.Handler) -> GCPClient {
    InventoryStubProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [InventoryStubProtocol.self]
    return GCPClient(session: URLSession(configuration: configuration)) { "secret-token" }
}

private func responseData(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

@Suite("Compute guest inventory", .serialized)
struct GuestInventoryTests {
    @Test func requestsGuestInventoryPathAndParsesPackages() async throws {
        let client = inventoryClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
            #expect(request.url?.path.hasSuffix("/zones/us-central1-a/instances/vm one/getGuestAttributes") == true)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query == [URLQueryItem(name: "queryPath", value: "guestInventory/")])
            return (200, responseData([
                "queryValue": ["items": [[
                    "namespace": "guestInventory", "key": "InstalledPackages",
                    "value": inventoryPayload,
                ]]],
            ]))
        }

        let loaded = try await client.packageInventory(
            project: "demo project", zone: "us-central1-a", instance: "vm one")
        let packages = try #require(loaded)
        #expect(packages.count == 3)
    }

    @Test func missingAttributeIsUnavailableRatherThanFailure() async throws {
        let client = inventoryClient { _ in
            (200, responseData(["queryValue": ["items": []]]))
        }
        let packages = try await client.packageInventory(project: "p", zone: "z", instance: "vm")
        #expect(packages == nil)
    }

    @Test func zoneFanOutIsThrottledFiltersWindowsAndKeepsFailures() async throws {
        let probe = ConcurrencyProbe()
        let windowsInstances: [[String: Any]] = (0..<9).map { index in
            [
                "name": "windows-\(index)", "zone": "zones/us-central1-a", "status": "RUNNING",
                "disks": [["licenses": ["projects/windows-cloud/global/licenses/windows-2022"]]],
            ]
        }
        let linux: [String: Any] = [
            "name": "linux-0", "zone": "zones/us-central1-a", "status": "RUNNING",
            "disks": [["licenses": ["projects/debian-cloud/global/licenses/debian-12"]]],
        ]
        let otherZone: [String: Any] = [
            "name": "windows-other-zone", "zone": "zones/us-east1-b", "status": "RUNNING",
            "disks": [["licenses": ["projects/windows-cloud/global/licenses/windows-2022"]]],
        ]
        let aggregatedResponse = responseData([
            "items": ["zones/us-central1-a": ["instances": windowsInstances + [linux]],
                      "zones/us-east1-b": ["instances": [otherZone]]],
        ])
        let client = inventoryClient { request in
            if request.url?.path.contains("/aggregated/instances") == true {
                return (200, aggregatedResponse)
            }
            let instance = request.url!.pathComponents.dropLast().last ?? ""
            probe.begin(instance: instance)
            Thread.sleep(forTimeInterval: 0.025)
            probe.end()
            if instance == "windows-4" {
                return (403, responseData(["error": ["status": "PERMISSION_DENIED"]]))
            }
            return (200, responseData([
                "queryValue": ["items": [[
                    "namespace": "guestInventory", "key": "InstalledPackages",
                    "value": inventoryPayload,
                ]]],
            ]))
        }

        let results = try await client.collectZonePackageInventory(
            project: "p", zone: "us-central1-a", maximumConcurrentRequests: 3)

        #expect(results.map(\.instance) == (0..<9).map { "windows-\($0)" })
        #expect(results.first { $0.instance == "windows-4" }?.packages == nil)
        #expect(results.filter { $0.packages != nil }.count == 8)
        #expect(probe.maximum > 1)
        #expect(probe.maximum <= 3)
        #expect(!probe.requestedInstances.contains("linux-0"))
        #expect(!probe.requestedInstances.contains("windows-other-zone"))
    }

    @Test func projectFanOutIncludesWindowsFromEveryZone() async throws {
        let aggregatedResponse = responseData([
            "items": [
                "zones/us-central1-a": ["instances": [[
                    "name": "windows-a", "zone": "zones/us-central1-a", "status": "RUNNING",
                    "disks": [["licenses": ["projects/windows-cloud/global/licenses/windows-2022"]]],
                ]]],
                "zones/us-east1-b": ["instances": [
                    [
                        "name": "windows-b", "zone": "zones/us-east1-b", "status": "RUNNING",
                        "disks": [["licenses": ["projects/windows-cloud/global/licenses/windows-2022"]]],
                    ],
                    [
                        "name": "linux-b", "zone": "zones/us-east1-b", "status": "RUNNING",
                        "disks": [["licenses": ["projects/debian-cloud/global/licenses/debian-12"]]],
                    ],
                ]],
            ],
        ])
        let client = inventoryClient { request in
            if request.url?.path.contains("/aggregated/instances") == true {
                return (200, aggregatedResponse)
            }
            return (200, responseData([
                "queryValue": ["items": [[
                    "namespace": "guestInventory", "key": "InstalledPackages",
                    "value": inventoryPayload,
                ]]],
            ]))
        }

        let results = try await client.collectProjectPackageInventory(project: "p")

        #expect(results.map(\.instance) == ["windows-a", "windows-b"])
        #expect(results.allSatisfy { $0.packages?.count == 3 })
    }
}
