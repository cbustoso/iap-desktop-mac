# Spec Tunnel — requirements (EARS)

Ref: `docs/feature-parity.md` §3 · ADR-0002 · Linear CBU-17 (epic CBU-10). Origen: `Google.Solutions.Iap/*`, `Core/ClientModel/Transport/*`.

## REQ-TUN-1 — WebSocket IAP
- WHEN se abre un túnel THEN el sistema SHALL conectar `wss://tunnel.cloudproxy.app/v4/connect?project&zone&instance&interface&port&_={guid}` con subprotocolo `relay.tunnel.cloudproxy.app`, `Origin: bot:iap-tunneler`, `Authorization: Bearer <access-token>`, `KeepAlive 60s`.
- El sistema SHALL mapear `403 → ConnectionDenied` (proxy bloquea WS) y `404 → BackendNotFound`.

## REQ-TUN-2 — SSH Relay v4 (fiel al original)
- El framing SHALL ser big-endian con tags `CONNECT_SUCCESS_SID=1, RECONNECT_SUCCESS_ACK=2, DATA=4, ACK=7, LONG_CLOSE=10` y closes `4000…4033/4047/4074`.
- La sesión SHALL guardar `Sid`, reintentar reconnect ×2 vía `reconnect?sid&ack`, `MaxReadDataPerAck=1MB`; el stream SHALL mantener cola unacked con `Resend` + `ProbeConnectionAsync`.

## REQ-TUN-3 — Listener local + pool
- El sistema SHALL exponer `127.0.0.1:{puerto}` (allowlist de clientes), con `PortFinder` determinista (proyecto/zona/nombre/puerto, 5 reintentos si denegado).
- El pool SHALL reutilizar túneles por `protocol+policy+instance+targetPort` y hacer `ProbeAsync` antes de entregar. Vista de túneles activos.

## REQ-TUN-4 — Transporte y proxy
- Base: **SwiftNIO + WebSocketKit** (o `Network.framework` con upgrade manual si la spec lo justifica); `URLSessionWebSocketTask` NO es base por falta de control `Host`/proxy/headers.
- El sistema SHALL aplicar proxy del sistema para `wss://` (HTTP CONNECT). mTLS/PSC degradan a público en v1 (M4).

## REQ-TUN-5 — Fallback gcloud (P1, no MVP)
- Si el nativo falla y existe `gcloud`, el sistema MAY lanzar `gcloud compute start-iap-tunnel` registrando la vía usada.

## Trazabilidad
REQ-TUN-1 → T-TUN-1 · REQ-TUN-2 → T-TUN-2,3 · REQ-TUN-3 → T-TUN-4,5 · REQ-TUN-4 → T-TUN-1,6 · REQ-TUN-5 → T-TUN-7 (P1).
