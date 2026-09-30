// TunnelKit T-TUN-1 tests: endpoint URIs (trazables a REQ-TUN-1).
import Testing
import Foundation
@testable import TunnelKit

@Suite("IapEndpoint")
struct IapEndpointTests {
    @Test func connectURLShape() throws {
        let endpoint = IapEndpoint(project: "p", zone: "europe-west1-b", instance: "vm-1", port: 22)
        let url = try #require(endpoint.connectURL())
        #expect(url.scheme == "wss")
        #expect(url.host == "tunnel.cloudproxy.app")
        #expect(url.path == "/v4/connect")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
        #expect(value("project") == "p")
        #expect(value("zone") == "europe-west1-b")
        #expect(value("instance") == "vm-1")
        #expect(value("interface") == "nic0")
        #expect(value("port") == "22")
        #expect(value("_") != nil)  // guid anti-caché
    }

    @Test func reconnectURLShape() throws {
        let url = try #require(IapEndpoint.reconnectURL(sid: "sid-1", ack: 42, zone: "z"))
        #expect(url.path == "/v4/reconnect")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
        #expect(value("sid") == "sid-1")
        #expect(value("ack") == "42")
        #expect(value("zone") == "z")
    }

    @Test func protocolConstants() {
        #expect(IapEndpoint.subprotocol == "relay.tunnel.cloudproxy.app")
        #expect(IapEndpoint.origin == "bot:iap-tunneler")
        #expect(IapEndpoint.keepAliveSeconds == 60)
    }
}
