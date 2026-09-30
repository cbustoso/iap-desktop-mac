# ADR-0002: Estrategia de túnel IAP — implementación nativa + fallback gcloud opcional

- Estado: **Propuesto** (Fase 0, pendiente de aprobación)
- Fecha: 2026-09-30
- Contexto: `Google.Solutions.Iap` (`IapClient`, `IapInstanceTarget`, `IapListener`, `Protocol/SshRelay{Session,Stream,Format,Constants}`, `Net/WebSocketStream`). Ver `docs/feature-parity.md` §3.

## Decisión

1. **`TunnelKit` nativo** como vía principal (P0):
   - WebSocket `wss://tunnel.cloudproxy.app/v4/connect?project&zone&instance&interface&port` (+ `reconnect?sid&ack`), subprotocolo `relay.tunnel.cloudproxy.app`, `Origin: bot:iap-tunneler`, Bearer OAuth, `KeepAlive 60s`.
   - Framing **SSH Relay v4** fiel al original (`SshRelayFormat` big-endian, `SshRelaySession` con `Sid` + reconnect ×2, `SshRelayStream` con cola unacked + `Resend` + `Probe`).
   - Listener local loopback (`NWListener`) + `TunnelPool` (actor, clave `protocol+policy+instance+targetPort`, `ProbeAsync` antes de `ListenAsync`, `PortFinder` determinista con reintentos).
   - Transporte: **SwiftNIO + WebSocketKit** (o `Network.framework` con upgrade manual) — `URLSessionWebSocketTask` no permite controlar `Host`/proxy/headers al nivel de `ClientWebSocket` (.NET). Proxy del sistema vía `CFNetworkCopyProxiesForURL` (HTTP CONNECT para `wss://`).
   - Tests primero: port de `TestSshRelayFormat/Stream`, `TestEcho/HttpOverIap`, `WebSocketServer` mock C# → mock Swift para `TunnelKit`.
2. **Fallback opcional `gcloud compute start-iap-tunnel`** (P1, no MVP):
   - Solo si el túnel nativo falla y `gcloud` está presente; vía `Process`, con mismo `TunnelPool` y logs que indiquen la vía usada.
   - No sustituye al nativo; sirve como escape en redes/proxies problemáticos.
3. **v1 sin mTLS/PSC completos**: `ServiceEndpointDirections` degrada a `Public`; `SystemPatch` Windows-only no se porta (ver matriz §1). mTLS → M4.

## Alternativas consideradas

1. **Solo `gcloud` como túnel**: rápido pero exige CLI instalado/autenticado aparte, rompe UX "la app lo gestiona todo" y el pool/estadísticas. Descartado como principal; válido como fallback.
2. **`URLSessionWebSocketTask` puro**: API mínima, sin control de `Host`/proxy/subprotocolo+headers simultáneos; riesgo de incompatibilidad con PSC/mTLS. Descartado como base.
3. **Portar `ClientWebSocket` vía .NET en macOS**: no nativo, firma/distribución inviable. Descartado.

## Consecuencias

- `TunnelKit` es el módulo de mayor riesgo (A) — asignado a Claude Code en M1, con revisión cruzada.
- Spec de `TunnelKit` debe fijar el framing binario y la máquina `SID/ACK` antes de codificar (Kiro: `specs/tunnel/`).

## Puerta de aprobación

- [ ] Confirmar NIO+WebSocketKit frente a `Network.framework` (detalle en spec, no bloquea matriz).
- [ ] Confirmar fallback `gcloud` como P1 opcional (no MVP).
