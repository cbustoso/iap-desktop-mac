/// Errores tipados de TunnelKit (specs/tunnel/design.md).
///
/// Mapeo handshake: HTTP 403 → `connectionDenied` (proxy bloquea WS),
/// HTTP 404 → `backendNotFound`.
public enum TunnelError: Error, Sendable, Equatable {
    case connectionDenied
    case backendNotFound
    case relayClosed(code: Int)
    case reconnectExhausted
    case portDenied
    case proxyBlocked
    case invalidURL
    case handshakeFailed(String)
}
