// GH-69: proxy corporativo (TunnelKit). Todo stub: ninguna llamada toca
// CFNetwork del sistema real ni la red. Verifica el mismo núcleo que
// `AuthKitTests/ProxyResolverTests.swift` (duplicado a propósito, ver cabecera
// de `Sources/TunnelKit/ProxyResolver.swift`) más el adaptador específico de
// `TunnelKit`: `ResolvedProxy.relayProxyConfig` → `ProxyConfig` para el
// `CONNECT` de `NIOWebSocketTransport`.
import CFNetwork
import Foundation
import Testing
@testable import TunnelKit

// `[AnyHashable: Any]` no es `Sendable` (contiene `Any`); estos fixtures son
// datos inmutables de solo lectura compartidos entre tests síncronos, igual
// de seguros que los `nonisolated(unsafe) static var handler` ya usados en
// `Tests/GCPClientTests`/`Tests/AuthKitTests` para el mismo propósito.
private func entry(type: String, host: String? = nil, port: Int? = nil) -> [AnyHashable: Any] {
    var dict: [AnyHashable: Any] = [ProxyResolver.typeKey: type]
    if let host { dict[ProxyResolver.hostKey] = host }
    if let port { dict[ProxyResolver.portKey] = port }
    return dict
}

nonisolated(unsafe) private let directEntry = entry(type: "kCFProxyTypeNone")
nonisolated(unsafe) private let httpEntry = entry(type: "kCFProxyTypeHTTP", host: "proxy.corp.local", port: 8080)
nonisolated(unsafe) private let httpsEntry = entry(type: "kCFProxyTypeHTTPS", host: "proxy.corp.local", port: 8443)
nonisolated(unsafe) private let socksEntry = entry(type: "kCFProxyTypeSOCKS", host: "proxy.corp.local", port: 1080)

private let tunnelURL = URL(string: "wss://tunnel.cloudproxy.app/v4/connect?project=p&zone=z&instance=i&interface=nic0&port=22")!

/// Contador simple para los stubs que deben registrar cuántas veces se
/// invocaron (p. ej. "no se consultó el sistema cuando el destino es PSC").
private final class CallCounter: @unchecked Sendable {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Registro simple de URLs vistas por un stub (p. ej. qué URL de PAC se pidió descargar).
private final class URLLog: @unchecked Sendable {
    private(set) var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}

@Suite("ProxyResolver (TunnelKit, GH-69)")
struct ProxyResolverTunnelKitTests {
    @Test func privateServiceConnectAlwaysBypassesTheProxyEvenWithoutConsultingTheSystem() async {
        let calls = CallCounter()
        let resolver = ProxyResolver(
            systemSettings: { calls.increment(); return [:] },
            proxiesForURL: { _, _ in [httpsEntry] })
        let result = await resolver.resolve(for: tunnelURL, destination: .privateServiceConnect)
        #expect(result == .direct)
        // Paridad `Options.Proxy=null si PSC` del cliente WebSocket original.
        #expect(calls.count == 0)
    }

    @Test func noSystemSettingsMeansDirect() async {
        let resolver = ProxyResolver(systemSettings: { nil })
        let result = await resolver.resolve(for: tunnelURL)
        #expect(result == .direct)
    }

    @Test func systemReportsNoProxyMeansDirect() async {
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [directEntry] })
        let result = await resolver.resolve(for: tunnelURL)
        #expect(result == .direct)
    }

    @Test func httpProxyEntryResolvesWithHostAndPort() async {
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [httpEntry] })
        let result = await resolver.resolve(for: tunnelURL)
        #expect(result == .http(host: "proxy.corp.local", port: 8080))
    }

    @Test func socksProxyDegradesToDirectSinceNIOWebSocketTransportHasNoSocksClient() async {
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [socksEntry] })
        let result = await resolver.resolve(for: tunnelURL)
        #expect(result == .direct)
    }

    @Test func pacWithInlineJavaScriptIsExecutedWithoutFetchingAnything() async {
        let fetchCalls = CallCounter()
        nonisolated(unsafe) let pacEntry: [AnyHashable: Any] = [
            ProxyResolver.typeKey: "kCFProxyTypeAutoConfigurationJavaScript",
            ProxyResolver.pacJavaScriptKey: "function FindProxyForURL(url, host) { return 'PROXY 10.0.0.1:3128'; }",
        ]
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [pacEntry] },
            fetchPACScript: { _ in fetchCalls.increment(); return "" },
            executePAC: { _, target in
                #expect(target == tunnelURL)
                return [entry(type: "kCFProxyTypeHTTP", host: "10.0.0.1", port: 3128)]
            })
        let result = await resolver.resolve(for: tunnelURL)
        #expect(result == .http(host: "10.0.0.1", port: 3128))
        #expect(fetchCalls.count == 0)
    }

    @Test func pacWithOnlyAURLIsFetchedThenExecuted() async {
        nonisolated(unsafe) let pacEntry: [AnyHashable: Any] = [
            ProxyResolver.typeKey: "kCFProxyTypeAutoConfigurationURL",
            ProxyResolver.pacURLKey: "https://intranet.corp.local/proxy.pac",
        ]
        let fetchedURLs = URLLog()
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [pacEntry] },
            fetchPACScript: { url in
                fetchedURLs.append(url)
                return "function FindProxyForURL(url, host) { return 'PROXY 10.0.0.1:3128'; }"
            },
            executePAC: { _, _ in [entry(type: "kCFProxyTypeHTTPS", host: "10.0.0.1", port: 3128)] })
        let result = await resolver.resolve(for: tunnelURL)
        #expect(result == .https(host: "10.0.0.1", port: 3128))
        // La variante `kCFProxyAutoConfigurationURLKey` como `String` (no `URL`)
        // también SHALL resolverse (`CFNetworkCopyProxiesForURL` puede devolver
        // cualquiera de las dos formas según la versión del SO).
        #expect(fetchedURLs.urls == [URL(string: "https://intranet.corp.local/proxy.pac")!])
    }

    @Test func pacScriptFetchFailureDegradesToDirectWithoutThrowing() async {
        struct NetworkDown: Error {}
        nonisolated(unsafe) let pacEntry: [AnyHashable: Any] = [
            ProxyResolver.typeKey: "kCFProxyTypeAutoConfigurationURL",
            ProxyResolver.pacURLKey: URL(string: "https://intranet.corp.local/proxy.pac")!,
        ]
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [pacEntry] },
            fetchPACScript: { _ in throw NetworkDown() })
        let result = await resolver.resolve(for: tunnelURL)
        #expect(result == .direct)
    }

    @Test func pacExecutionFailureDegradesToDirectWithoutThrowing() async {
        struct PACScriptBroken: Error {}
        nonisolated(unsafe) let pacEntry: [AnyHashable: Any] = [
            ProxyResolver.typeKey: "kCFProxyTypeAutoConfigurationJavaScript",
            ProxyResolver.pacJavaScriptKey: "not actually valid javascript {{{",
        ]
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [pacEntry] },
            executePAC: { _, _ in throw PACScriptBroken() })
        let result = await resolver.resolve(for: tunnelURL)
        #expect(result == .direct)
    }

    // MARK: - Adaptador `ProxyConfig` (`NIOWebSocketTransport.proxy`)

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
}
