import CFNetwork
import Foundation

// GH-69: proxy corporativo. Paridad `docs/feature-parity.md` §"Proxy
// corporativo" (`WebRequest.DefaultWebProxy` + `NtlmResilientWebRequestHandler`
// del original) y `specs/auth/design.md` ("Proxy: `ProxyResolver`
// (`CFNetworkCopyProxiesForURL`) inyectado en
// `URLSessionConfiguration.connectionProxyDictionary`"). Resuelve el proxy
// del sistema (incluida ejecución de PAC) para las llamadas HTTPS de
// `AuthKit` (`oauth2.googleapis.com`/`sts.googleapis.com`).
//
// NOTA DE DUPLICACIÓN: este tipo también existe, con el mismo contenido
// nuclear, en `Sources/TunnelKit/ProxyResolver.swift` (para el `CONNECT` del
// túnel `wss://`). `AuthKit` y `TunnelKit` no se dependen entre sí y esta
// tarea tiene prohibido tocar `Package.swift` (que es donde se declararía un
// target compartido, p. ej. `ProxyKit`), así que el núcleo se duplica a
// propósito en vez de inventar una dependencia cruzada no declarada. Si en el
// futuro se permite tocar `Package.swift`, extraer este tipo a un target
// propio y hacer que ambos lo importen, eliminando la copia.
//
// Sin soporte NTLM (irrelevante en macOS, paridad explícita de la tabla de
// feature-parity) ni SOCKS (ningún consumidor —`URLSession` para AuthKit,
// `HTTP CONNECT` para TunnelKit— lo necesita): ambos degradan a conexión
// directa si el sistema solo ofrece un proxy SOCKS.

/// Resultado de resolver el proxy del sistema (incluida la ejecución de un
/// script PAC) para una URL de destino.
public enum ResolvedProxy: Sendable, Equatable {
    /// Sin proxy: conectar directo al destino.
    case direct
    /// Proxy HTTP clásico (`CONNECT` para túneles, forward normal para HTTP).
    case http(host: String, port: Int)
    /// Proxy HTTPS (mismo uso que `.http`; el sistema separa ambos casos).
    case https(host: String, port: Int)
}

/// Resuelve el proxy del sistema para una URL, incluyendo PAC
/// (`CFNetworkCopyProxiesForURL` + `CFNetworkExecuteProxyAutoConfigurationScript`).
///
/// Todas las llamadas a CFNetwork/red están detrás de closures inyectables
/// (`systemSettings`, `proxiesForURL`, `fetchPACScript`, `executePAC`) con
/// implementaciones "live" por defecto: los tests sustituyen estas cuatro
/// funciones por stubs puros, sin tocar el sistema ni la red real.
public struct ProxyResolver: Sendable {
    /// Tipo de destino. PSC (Private Service Connect) SIEMPRE bypassa el
    /// proxy del sistema, paridad exacta con el original: `UseProxy=false`
    /// si PSC en `PscAndMtlsAwareHttpClientFactory`, `Options.Proxy=null` si
    /// PSC en el cliente WebSocket. No hay PAC ni excepción que lo anule.
    public enum Destination: Sendable, Equatable {
        case publicEndpoint
        case privateServiceConnect
    }

    public enum ResolveError: Error, Equatable, Sendable {
        /// El script PAC no se pudo descargar (red, 4xx/5xx, encoding).
        case pacScriptFetchFailed
    }

    public typealias SystemSettingsProvider = @Sendable () -> [AnyHashable: Any]?
    public typealias ProxiesForURLProvider = @Sendable (URL, [AnyHashable: Any]) -> [[AnyHashable: Any]]
    /// Descarga el script PAC cuando el sistema solo da una URL
    /// (`ProxyAutoConfigURLString`), no el JS inline. Live: `URLSession`.
    public typealias PACScriptFetcher = @Sendable (URL) async throws -> String
    /// `CFNetworkExecuteProxyAutoConfigurationScript` (vía `CFRunLoop`).
    public typealias PACExecutor = @Sendable (String, URL) throws -> [[AnyHashable: Any]]

    private let systemSettings: SystemSettingsProvider
    private let proxiesForURL: ProxiesForURLProvider
    private let fetchPACScript: PACScriptFetcher
    private let executePAC: PACExecutor

    public init(
        systemSettings: @escaping SystemSettingsProvider = ProxyResolver.liveSystemSettings,
        proxiesForURL: @escaping ProxiesForURLProvider = ProxyResolver.liveProxiesForURL,
        fetchPACScript: @escaping PACScriptFetcher = ProxyResolver.liveFetchPACScript,
        executePAC: @escaping PACExecutor = ProxyResolver.liveExecutePAC
    ) {
        self.systemSettings = systemSettings
        self.proxiesForURL = proxiesForURL
        self.fetchPACScript = fetchPACScript
        self.executePAC = executePAC
    }

    /// Resuelve el proxy a usar para `url`. Nunca lanza: cualquier fallo al
    /// resolver PAC (red caída, script roto, timeout) degrada a `.direct`
    /// (fail-open, paridad con el espíritu de "nunca bloquear la conexión
    /// por un PAC roto" — el original tampoco falla duro por esto).
    public func resolve(for url: URL, destination: Destination = .publicEndpoint) async -> ResolvedProxy {
        guard destination != .privateServiceConnect else { return .direct }
        guard let settings = systemSettings() else { return .direct }
        let entries = proxiesForURL(url, settings)
        guard let first = entries.first else { return .direct }
        if let resolved = Self.classify(first) { return resolved }

        do {
            if let script = first[Self.pacJavaScriptKey] as? String {
                return Self.firstResolved(try executePAC(script, url))
            }
            if let pacURL = Self.asURL(first[Self.pacURLKey]) {
                let script = try await fetchPACScript(pacURL)
                return Self.firstResolved(try executePAC(script, url))
            }
        } catch {
            return .direct
        }
        return .direct
    }

    private static func asURL(_ value: Any?) -> URL? {
        (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    private static func firstResolved(_ entries: [[AnyHashable: Any]]) -> ResolvedProxy {
        for entry in entries {
            if let resolved = classify(entry) { return resolved }
        }
        return .direct
    }

    // MARK: - Claves CFNetwork (shape de `CFNetworkCopyProxiesForURL`)

    // `static var` computada (no `let`): un `AnyHashable` global almacenado
    // dispara "not concurrency-safe" en Swift 6 porque `AnyHashable` no es
    // `Sendable`; recalcularla en cada acceso evita el almacenamiento global.
    static var typeKey: AnyHashable { kCFProxyTypeKey as AnyHashable }
    static var hostKey: AnyHashable { kCFProxyHostNameKey as AnyHashable }
    static var portKey: AnyHashable { kCFProxyPortNumberKey as AnyHashable }
    static var pacURLKey: AnyHashable { kCFProxyAutoConfigurationURLKey as AnyHashable }
    static var pacJavaScriptKey: AnyHashable { kCFProxyAutoConfigurationJavaScriptKey as AnyHashable }

    private static let typeNone = kCFProxyTypeNone as String
    private static let typeHTTP = kCFProxyTypeHTTP as String
    private static let typeHTTPS = kCFProxyTypeHTTPS as String
    private static let typeSOCKS = kCFProxyTypeSOCKS as String

    /// `nil` cuando la entrada es de autoconfiguración (PAC): el llamador
    /// debe ejecutar el script y clasificar su resultado.
    static func classify(_ entry: [AnyHashable: Any]) -> ResolvedProxy? {
        guard let type = entry[typeKey] as? String else { return nil }
        if type == typeNone { return .direct }
        if type == typeHTTP {
            guard let host = entry[hostKey] as? String else { return .direct }
            return .http(host: host, port: (entry[portKey] as? Int) ?? 80)
        }
        if type == typeHTTPS {
            guard let host = entry[hostKey] as? String else { return .direct }
            return .https(host: host, port: (entry[portKey] as? Int) ?? 443)
        }
        // SOCKS: ningún consumidor lo soporta (ver nota de cabecera) → directo.
        if type == typeSOCKS { return .direct }
        return nil
    }

    // MARK: - Implementaciones "live" (CFNetwork / URLSession reales)

    public static let liveSystemSettings: SystemSettingsProvider = {
        CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [AnyHashable: Any]
    }

    public static let liveProxiesForURL: ProxiesForURLProvider = { url, settings in
        let array = CFNetworkCopyProxiesForURL(url as CFURL, settings as CFDictionary)
            .takeRetainedValue() as NSArray
        return array.compactMap { $0 as? [AnyHashable: Any] }
    }

    public static let liveFetchPACScript: PACScriptFetcher = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let text = String(data: data, encoding: .utf8)
        else { throw ResolveError.pacScriptFetchFailed }
        return text
    }

    /// Puente síncrono sobre el `CFRunLoop` actual: `info` del contexto lleva
    /// un puntero `Unmanaged` a `PACResultBox` para que el callback en C
    /// (sin captura de contexto Swift) pueda escribir el resultado.
    public static let liveExecutePAC: PACExecutor = { script, targetURL in
        let boxPointer = Unmanaged.passRetained(PACResultBox()).toOpaque()
        defer { Unmanaged<PACResultBox>.fromOpaque(boxPointer).release() }
        var context = CFStreamClientContext(
            version: 0, info: boxPointer, retain: nil, release: nil, copyDescription: nil)

        let callback: CFProxyAutoConfigurationResultCallback = { client, proxyList, error in
            let box = Unmanaged<PACResultBox>.fromOpaque(client).takeUnretainedValue()
            if let error {
                box.result = .failure(error)
            } else {
                box.result = .success((proxyList as NSArray) as? [[AnyHashable: Any]] ?? [])
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }

        let runLoop = CFRunLoopGetCurrent()
        let source = CFNetworkExecuteProxyAutoConfigurationScript(
            script as CFString, targetURL as CFURL, callback, &context)
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        defer { CFRunLoopRemoveSource(runLoop, source, .defaultMode) }
        // 5 s: el propio PAC ya corre con timeout de red interno de CFNetwork;
        // esto es un cinturón de seguridad para no colgar la app si el
        // callback nunca llega (script roto, host DNS inexistente, etc.).
        CFRunLoopRunInMode(.defaultMode, 5.0, false)

        guard let result = Unmanaged<PACResultBox>.fromOpaque(boxPointer).takeUnretainedValue().result
        else { return [] }
        switch result {
        case .success(let entries): return entries
        case .failure(let error): throw error
        }
    }
}

/// `@unchecked`: solo lo toca el callback de `CFNetworkExecuteProxyAutoConfigurationScript`
/// (siempre en el mismo run loop/hilo que lo programó) y, después, quien lo lee.
final class PACResultBox: @unchecked Sendable {
    var result: Result<[[AnyHashable: Any]], Error>?
}

// MARK: - Adaptador AuthKit: `URLSessionConfiguration.connectionProxyDictionary`

extension ResolvedProxy {
    /// Diccionario en el "shape" de `URLSessionConfiguration.connectionProxyDictionary`
    /// (`Enable`/`Proxy`/`Port`, el mismo que devuelve `CFNetworkCopySystemProxySettings`)
    /// — DISTINTO del shape `Type`/`HostName`/`PortNumber` de
    /// `CFNetworkCopyProxiesForURL` que usa `ProxyResolver` internamente.
    /// `nil`/vacío para `.direct` (sin entradas: `URLSession` conecta directo).
    public var connectionProxyDictionary: [AnyHashable: Any] {
        switch self {
        case .direct:
            return [:]
        case .http(let host, let port):
            return [
                kCFNetworkProxiesHTTPEnable as AnyHashable: 1,
                kCFNetworkProxiesHTTPProxy as AnyHashable: host,
                kCFNetworkProxiesHTTPPort as AnyHashable: port,
            ]
        case .https(let host, let port):
            return [
                kCFNetworkProxiesHTTPSEnable as AnyHashable: 1,
                kCFNetworkProxiesHTTPSProxy as AnyHashable: host,
                kCFNetworkProxiesHTTPSPort as AnyHashable: port,
            ]
        }
    }
}

extension ProxyResolver {
    /// Copia `base` y le aplica el proxy resuelto para `url` como
    /// `connectionProxyDictionary`. Pensado para las llamadas HTTPS de
    /// `AuthKit` a `oauth2.googleapis.com`/`sts.googleapis.com`
    /// (`TokenClient`, `RevokeClient`): se les pasa esta configuración en
    /// vez de `URLSessionConfiguration.default`/`.ephemeral` directo.
    public func configuredSessionConfiguration(
        base: URLSessionConfiguration = .ephemeral, for url: URL, destination: Destination = .publicEndpoint
    ) async -> URLSessionConfiguration {
        let resolved = await resolve(for: url, destination: destination)
        let dictionary = resolved.connectionProxyDictionary
        guard !dictionary.isEmpty else { return base }
        base.connectionProxyDictionary = dictionary
        return base
    }
}
