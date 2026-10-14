// GH-69/GH-70: adaptador de TunnelKit sobre el `ProxyResolver` compartido
// (`ResolvedProxy.relayProxyConfig` → `ProxyConfig` para el `CONNECT` de
// `NIOWebSocketTransport`). El núcleo (PSC, PAC, SOCKS, fail-open) se prueba
// una sola vez en `AuthKitTests/ProxyResolverTests.swift`. Todo stub.
import AuthKit
import CFNetwork
import Foundation
import Testing
@testable import TunnelKit

private let tunnelURL = URL(string: "wss://tunnel.cloudproxy.app/v4/connect?project=p&zone=z&instance=i&interface=nic0&port=22")!

/// Entrada HTTPS con las claves públicas de CFNetwork (shape de
/// `CFNetworkCopyProxiesForURL`). `nonisolated(unsafe)`: dato inmutable.
nonisolated(unsafe) private let httpsEntry: [AnyHashable: Any] = [
    kCFProxyTypeKey as AnyHashable: kCFProxyTypeHTTPS as String,
    kCFProxyHostNameKey as AnyHashable: "proxy.corp.local",
    kCFProxyPortNumberKey as AnyHashable: 8443,
]

@Suite("ProxyResolver (TunnelKit, GH-69)")
struct ProxyResolverTunnelKitTests {
    @Test func relayProxyConfigConvertsHttpAndHttpsToTheSameShape() {
        #expect(ResolvedProxy.direct.relayProxyConfig == nil)
        #expect(ResolvedProxy.http(host: "proxy.corp.local", port: 8080).relayProxyConfig
            == ProxyConfig(host: "proxy.corp.local", port: 8080))
        #expect(ResolvedProxy.https(host: "proxy.corp.local", port: 8443).relayProxyConfig
            == ProxyConfig(host: "proxy.corp.local", port: 8443))
    }

    @Test func relayProxyConfigHelperResolvesEndToEndFromTheResolver() async {
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [httpsEntry] })
        let config = await resolver.relayProxyConfig(for: tunnelURL)
        #expect(config == ProxyConfig(host: "proxy.corp.local", port: 8443))
    }

    @Test func relayProxyConfigHelperIsNilForPrivateServiceConnect() async {
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [httpsEntry] })
        let config = await resolver.relayProxyConfig(for: tunnelURL, destination: .privateServiceConnect)
        #expect(config == nil)
    }

    @Test func relayProxyConfigHelperIsNilWhenDirect() async {
        let resolver = ProxyResolver(systemSettings: { nil })
        let config = await resolver.relayProxyConfig(for: tunnelURL)
        #expect(config == nil)
    }

    /// GH-70: hay un único tipo; el de TunnelKit es el de AuthKit.
    @Test func resolverTypeIsTheSharedOne() {
        let shared: AuthKit.ProxyResolver = ProxyResolver(systemSettings: { nil })
        _ = shared
        #expect(String(reflecting: ProxyResolver.self) == "AuthKit.ProxyResolver")
        #expect(String(reflecting: ResolvedProxy.self) == "AuthKit.ResolvedProxy")
    }
}
