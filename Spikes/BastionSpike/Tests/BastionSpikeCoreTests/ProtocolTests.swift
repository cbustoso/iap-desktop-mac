import Foundation
import Testing
@testable import BastionSpikeCore

@Suite("Protocolo Bastion (research §3.3)")
struct ProtocolTests {
    static let vm = ResourceID.virtualMachine(subscription: "sub-1", resourceGroup: "rg-1", name: "vm 1")

    static func form(_ request: URLRequest) -> [(String, String)] {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        return body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
    }

    @Test("POST /api/tokens: form-urlencoded con resourceId, protocol, workloadHostPort, aztoken; sin token ni Authorization")
    func firstTokenRequest() {
        let plane = BastionDataPlane(dnsName: "bst-1.bastion.azure.com", transport: FakeHTTP.bastion())
        let request = plane.tokenRequest(resourceID: Self.vm, port: 22, azToken: "arm.token.value", previous: nil)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://bst-1.bastion.azure.com/api/tokens")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Node-Id") == nil)
        let fields = Self.form(request)
        #expect(fields.map(\.0) == ["resourceId", "protocol", "workloadHostPort", "aztoken"])
        #expect(fields.map(\.1) == [Self.vm, "tcptunnel", "22", "arm.token.value"])
        // quote_plus: `/` y el espacio van codificados.
        let raw = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(raw.hasPrefix("resourceId=%2Fsubscriptions%2Fsub-1%2F"))
        #expect(raw.contains("vm%201"))
    }

    @Test("POST encadenado: añade token=<authToken previo> y X-Node-Id")
    func chainedTokenRequest() {
        let plane = BastionDataPlane(dnsName: "bst-1.bastion.azure.com", transport: FakeHTTP.bastion())
        let previous = BastionSessionTokens(authToken: "prev-auth", nodeId: "node-9", websocketToken: "ws")
        let request = plane.tokenRequest(resourceID: Self.vm, port: 3389, azToken: "t", previous: previous)

        #expect(request.value(forHTTPHeaderField: "X-Node-Id") == "node-9")
        let fields = Self.form(request)
        #expect(fields.map(\.0) == ["resourceId", "protocol", "workloadHostPort", "aztoken", "token"])
        #expect(fields.last?.1 == "prev-auth")
        #expect(fields[2].1 == "3389")
    }

    @Test("WebSocket: wss://{dns}/webtunnelv2/{wsToken}?X-Node-Id={nodeId}, solo Origin")
    func webSocketRequest() {
        let tokens = BastionSessionTokens(authToken: "a", nodeId: "node-1", websocketToken: "ws+tok/en=")
        let request = WebSocketRequest.bastion(dnsName: "bst-1.bastion.azure.com", tokens: tokens)

        #expect(request.scheme == "wss")
        #expect(request.host == "bst-1.bastion.azure.com")
        #expect(request.port == 443)
        #expect(request.path == "/webtunnelv2/ws+tok/en=")
        #expect(request.query == "X-Node-Id=node-1")
        #expect(request.headers == [HeaderField(name: "Origin", value: "https://bst-1.bastion.azure.com")])
        let names = Set(request.headers.map { $0.name.lowercased() })
        #expect(!names.contains("authorization"))
        #expect(!names.contains("sec-websocket-protocol"))
        #expect(!request.description.contains("ws+tok/en="))
    }

    @Test("Sesión: POSTs encadenados, un único DELETE al cerrar la última conexión; el segundo da 404")
    func sessionLifecycle() async throws {
        let http = FakeHTTP.bastion()
        let plane = BastionDataPlane(dnsName: "bst-1.bastion.azure.com", transport: http, log: LogCapture().makeLog())
        let manager = BastionSessionManager(dataPlane: plane, resourceID: Self.vm, port: 22, log: LogCapture().makeLog()) { "arm-token" }

        let first = try await manager.open()
        let second = try await manager.open()
        #expect(first.authToken == "auth-token-0")
        #expect(second.authToken == "auth-token-1")
        #expect(Self.form(http.seen[1]).last?.1 == "auth-token-0")

        await manager.release()
        #expect(http.seen.filter { $0.httpMethod == "DELETE" }.isEmpty)
        await manager.release()
        await manager.release()
        await manager.shutdown()

        let deletes = http.seen.filter { $0.httpMethod == "DELETE" }
        #expect(deletes.count == 1)
        #expect(deletes.first?.url?.absoluteString == "https://bst-1.bastion.azure.com/api/tokens/auth-token-1")
        #expect(deletes.first?.value(forHTTPHeaderField: "X-Node-Id") == "node-1")

        let again = try await plane.deleteTokens(try #require(await manager.lastDeleted))
        #expect(again == .alreadyGone)
    }

    @Test("POST ≠ 200 → error con el message del servidor")
    func tokenError() async {
        let http = FakeHTTP { _, _ in HTTPResponse(status: 403, body: Data(#"{"message":"Forbidden"}"#.utf8)) }
        let plane = BastionDataPlane(dnsName: "bst", transport: http, log: LogCapture().makeLog())
        await #expect(throws: BastionError.http(operation: "POST /api/tokens", status: 403, message: "Forbidden")) {
            try await plane.requestTokens(resourceID: Self.vm, port: 22, azToken: "t", previous: nil)
        }
    }

    @Test("GET ARM del Bastion: api-version 2024-01-01 y gate SKU/enableTunneling")
    func bastionHostGate() async throws {
        let bastionID = ResourceID.bastionHost(subscription: "s", resourceGroup: "rg", name: "bh")
        let request = BastionHost.request(resourceID: bastionID, armToken: "arm")
        #expect(request.url?.absoluteString == "https://management.azure.com\(bastionID)?api-version=2024-01-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer arm")

        @Sendable func host(_ sku: String, tunneling: Bool?) -> String {
            let flag = tunneling.map { #","enableTunneling":\#($0)"# } ?? ""
            return #"{"id":"\#(bastionID)","name":"bh","location":"eastus","sku":{"name":"\#(sku)"},"properties":{"dnsName":"bst-x.bastion.azure.com"\#(flag)}}"#
        }
        let standard = Data(host("Standard", tunneling: true).utf8)
        let ok = FakeHTTP { _, _ in HTTPResponse(status: 200, body: standard) }
        let fetched = try await BastionHost.fetch(resourceID: bastionID, armToken: "arm", transport: ok, log: LogCapture().makeLog())
        #expect(try fetched.tunnelEndpoint() == "bst-x.bastion.azure.com")

        let basic = try JSONDecoder().decode(BastionHost.self, from: Data(host("Basic", tunneling: nil).utf8))
        #expect(throws: BastionError.skuNotSupported("Basic")) { try basic.tunnelEndpoint() }
        let disabled = try JSONDecoder().decode(BastionHost.self, from: Data(host("Premium", tunneling: false).utf8))
        #expect(throws: BastionError.tunnelingDisabled) { try disabled.tunnelEndpoint() }
    }
}
