# T-TUN-1 — Decisión de transporte WebSocket (spike)

Fecha: 2026-09-30 · CBU-22 · `Sources/TunnelKit/WebSocketTransport.swift`

## Decisión: SwiftNIO + WebSocketKit

Verificado contra el código fuente real (`websocket-kit` 2.16.2, resuelto por SPM):

| Requisito IAP | NIO + WebSocketKit | `URLSessionWebSocketTask` | `Network.framework` |
|---|---|---|---|
| Headers custom (`Authorization`, `Origin`, `User-Agent`) | ✅ `headers: HTTPHeaders` en `connect` | ⚠️ API limitada | ✅ manual |
| Subprotocolo `relay.tunnel.cloudproxy.app` | ✅ vía header `Sec-WebSocket-Protocol` (pendiente validar en vivo, T-TUN-6) | ❌ sin control | ✅ manual |
| Proxy HTTP CONNECT para `wss://` | ✅ variante `connect(..., proxy:, proxyPort:)` | ❌ | ✅ manual (mucho código) |
| TLS `wss` | ✅ NIOSSL transitivo | ✅ | ✅ manual |
| Ping keepalive 60 s | ✅ `sendPing` (implementado en `NIORelayChannel`) | ✅ | ✅ manual |
| Mapeo 403/404 handshake | ⚠️ `mapHandshakeError` provisional → afinar en T-TUN-4/6 | ❌ | ✅ manual |

Descartados `URLSessionWebSocketTask` (sin control de subprotocolo/headers/proxy simultáneos) y `Network.framework` (reimplementar upgrade WS + TLS + proxy = reescribir NIO).

## Entregado en este spike
- `IapEndpoint` (URIs connect/reconnect puras, testeables) + `TunnelError` tipado.
- `NIOWebSocketTransport.connect(to:accessToken:proxy:)` → `RelayChannel` (actor, `send`/`incoming`/`close`, keepalive 60 s, cierre con `shutdownGracefully`).
- Deps fijadas: `swift-nio` ≥ 2.65, `websocket-kit` ≥ 2.14 (`Package.resolved` commiteado).

## Riesgos abiertos (no bloquean)
1. Confirmar en vivo que el servidor acepta el subprotocolo por header (mock T-TUN-6).
2. Afinar mapeo 403 → `connectionDenied` / 404 → `backendNotFound` (T-TUN-4).
3. Proxy con PAC del sistema (`CFNetworkCopyProxiesForURL` → `ProxyConfig`, M4).
