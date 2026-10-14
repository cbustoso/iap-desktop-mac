// GH-69: proxy corporativo (AuthKit). Todo stub: ninguna llamada toca
// CFNetwork del sistema real ni la red (ni `URLSession.shared` ni
// `CFNetworkCopySystemProxySettings`/`CFNetworkExecuteProxyAutoConfigurationScript`
// reales) — se inyectan las cuatro dependencias de `ProxyResolver`
// (`systemSettings`, `proxiesForURL`, `fetchPACScript`, `executePAC`).
import CFNetwork
import Foundation
import Testing
@testable import AuthKit

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

@Suite("ProxyResolver (AuthKit, GH-69)")
struct ProxyResolverAuthKitTests {
    @Test func privateServiceConnectAlwaysBypassesTheProxyEvenWithoutConsultingTheSystem() async {
        let calls = CallCounter()
        let resolver = ProxyResolver(
            systemSettings: { calls.increment(); return [:] },
            proxiesForURL: { _, _ in [httpsEntry] })
        let result = await resolver.resolve(
            for: URL(string: "https://psc-endpoint.example.com")!, destination: .privateServiceConnect)
        #expect(result == .direct)
        // Paridad `UseProxy=false si PSC`: ni siquiera se consulta el sistema.
        #expect(calls.count == 0)
    }

    @Test func noSystemSettingsMeansDirect() async {
        let resolver = ProxyResolver(systemSettings: { nil })
        let result = await resolver.resolve(for: URL(string: "https://oauth2.googleapis.com/token")!)
        #expect(result == .direct)
    }

    @Test func systemReportsNoProxyMeansDirect() async {
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [directEntry] })
        let result = await resolver.resolve(for: URL(string: "https://sts.googleapis.com/v1/token")!)
        #expect(result == .direct)
    }

    @Test func httpProxyEntryResolvesWithHostAndPort() async {
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [httpEntry] })
        let result = await resolver.resolve(for: URL(string: "https://oauth2.googleapis.com/token")!)
        #expect(result == .http(host: "proxy.corp.local", port: 8080))
    }

    @Test func httpsProxyEntryResolvesWithHostAndPort() async {
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [httpsEntry] })
        let result = await resolver.resolve(for: URL(string: "https://sts.googleapis.com")!)
        #expect(result == .https(host: "proxy.corp.local", port: 8443))
    }

    @Test func socksProxyDegradesToDirectSinceNoConsumerSupportsIt() async {
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [socksEntry] })
        let result = await resolver.resolve(for: URL(string: "https://oauth2.googleapis.com/token")!)
        #expect(result == .direct)
    }

    @Test func httpEntryWithoutHostDegradesToDirect() async {
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [entry(type: "kCFProxyTypeHTTP")] })
        let result = await resolver.resolve(for: URL(string: "https://oauth2.googleapis.com")!)
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
            executePAC: { script, _ in
                #expect(script.contains("FindProxyForURL"))
                return [entry(type: "kCFProxyTypeHTTP", host: "10.0.0.1", port: 3128)]
            })
        let result = await resolver.resolve(for: URL(string: "https://oauth2.googleapis.com/token")!)
        #expect(result == .http(host: "10.0.0.1", port: 3128))
        #expect(fetchCalls.count == 0)
    }

    @Test func pacWithOnlyAURLIsFetchedThenExecuted() async {
        nonisolated(unsafe) let pacEntry: [AnyHashable: Any] = [
            ProxyResolver.typeKey: "kCFProxyTypeAutoConfigurationURL",
            ProxyResolver.pacURLKey: URL(string: "https://intranet.corp.local/proxy.pac")!,
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
        let result = await resolver.resolve(for: URL(string: "https://sts.googleapis.com")!)
        #expect(result == .https(host: "10.0.0.1", port: 3128))
        #expect(fetchedURLs.urls == [URL(string: "https://intranet.corp.local/proxy.pac")!])
    }

    @Test func pacFirstEntryUnresolvedFallsBackToSubsequentEntries() async {
        // El PAC puede devolver "PROXY a; PROXY b; DIRECT": si la primera
        // entrada no clasifica (dato corrupto), se intenta con la siguiente.
        nonisolated(unsafe) let pacEntry: [AnyHashable: Any] = [
            ProxyResolver.typeKey: "kCFProxyTypeAutoConfigurationJavaScript",
            ProxyResolver.pacJavaScriptKey: "function FindProxyForURL(url, host) { return 'DIRECT'; }",
        ]
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [pacEntry] },
            executePAC: { _, _ in
                [[ProxyResolver.typeKey: "kCFProxyTypeUnknownFutureCase"], directEntry]
            })
        let result = await resolver.resolve(for: URL(string: "https://oauth2.googleapis.com")!)
        #expect(result == .direct)
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
        let result = await resolver.resolve(for: URL(string: "https://oauth2.googleapis.com")!)
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
        let result = await resolver.resolve(for: URL(string: "https://sts.googleapis.com")!)
        #expect(result == .direct)
    }

    @Test func connectionProxyDictionaryShapeMatchesURLSessionConfigurationExpectations() {
        #expect(ResolvedProxy.direct.connectionProxyDictionary.isEmpty)

        let http = ResolvedProxy.http(host: "proxy.corp.local", port: 8080).connectionProxyDictionary
        #expect(http[kCFNetworkProxiesHTTPEnable as AnyHashable] as? Int == 1)
        #expect(http[kCFNetworkProxiesHTTPProxy as AnyHashable] as? String == "proxy.corp.local")
        #expect(http[kCFNetworkProxiesHTTPPort as AnyHashable] as? Int == 8080)

        let https = ResolvedProxy.https(host: "proxy.corp.local", port: 8443).connectionProxyDictionary
        #expect(https[kCFNetworkProxiesHTTPSEnable as AnyHashable] as? Int == 1)
        #expect(https[kCFNetworkProxiesHTTPSProxy as AnyHashable] as? String == "proxy.corp.local")
        #expect(https[kCFNetworkProxiesHTTPSPort as AnyHashable] as? Int == 8443)
    }

    @Test func configuredSessionConfigurationAppliesTheDictionaryOnlyWhenNotDirect() async throws {
        let directResolver = ProxyResolver(systemSettings: { nil })
        let directConfig = await directResolver.configuredSessionConfiguration(
            base: .ephemeral, for: URL(string: "https://oauth2.googleapis.com/token")!)
        #expect(directConfig.connectionProxyDictionary == nil)

        let proxiedResolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [httpsEntry] })
        let proxiedConfig = await proxiedResolver.configuredSessionConfiguration(
            base: .ephemeral, for: URL(string: "https://sts.googleapis.com")!)
        let dict = try #require(proxiedConfig.connectionProxyDictionary)
        #expect(dict[kCFNetworkProxiesHTTPSProxy as AnyHashable] as? String == "proxy.corp.local")
    }

    @Test func privateServiceConnectSkipsEvenAConfiguredCorporateProxyInTheSessionConfiguration() async {
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { _, _ in [httpsEntry] })
        let config = await resolver.configuredSessionConfiguration(
            base: .ephemeral, for: URL(string: "https://psc-endpoint.example.com")!,
            destination: .privateServiceConnect)
        #expect(config.connectionProxyDictionary == nil)
    }
}
