import AuthKit
import Foundation

// GH-70: el núcleo de `ProxyResolver`/`ResolvedProxy` vive solo en
// `Sources/AuthKit/ProxyResolver.swift` (antes duplicado aquí). Este fichero
// conserva únicamente lo específico de TunnelKit: la conversión a su
// `ProxyConfig` para el `HTTP CONNECT` de `NIOWebSocketTransport`.

// MARK: - Adaptador TunnelKit: `ProxyConfig` (HTTP CONNECT del túnel wss://)

extension ResolvedProxy {
    /// Convierte a la `ProxyConfig` ya existente de `TunnelKit`
    /// (`Sources/TunnelKit/WebSocketTransport.swift`, host+port para el
    /// `CONNECT` de `NIOWebSocketTransport`). `.http`/`.https` producen el
    /// mismo `ProxyConfig`: ambos son un `CONNECT` HTTP normal hacia el
    /// proxy, la distinción de "HTTP vs HTTPS proxy" solo determina qué
    /// entrada del sistema aplica, no cómo se habla con él.
    public var relayProxyConfig: ProxyConfig? {
        switch self {
        case .direct: return nil
        case .http(let host, let port), .https(let host, let port):
            return ProxyConfig(host: host, port: port)
        }
    }
}

extension ProxyResolver {
    /// Resuelve directamente a un `ProxyConfig?` listo para
    /// `NIOWebSocketTransport.proxy` (`nil` = conexión directa).
    public func relayProxyConfig(for url: URL, destination: Destination = .publicEndpoint) async -> ProxyConfig? {
        await resolve(for: url, destination: destination).relayProxyConfig
    }
}
