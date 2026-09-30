# Mock server protocolo IAP + estrategia de tests (CBU-21, M0)

Origen: `Google.Solutions.Iap.Test/Util/WebSocketServer.cs`, `TestSshRelay*.cs`, `TestEchoOverIap*.cs`, `TestHttpOverIap*.cs`.

## Estrategia

1. **Portar `WebSocketServer` C# → `MockIAPRelayServer` Swift** (solo en `Tests/TunnelKitTests`, nunca en producto):
   - Acepta WS en loopback, valida subprotocolo `relay.tunnel.cloudproxy.app` + `Origin`.
   - Implementa el lado servidor del framing v4 (responde `CONNECT_SUCCESS_SID`, `ACK`s, eco `DATA`, `LONG_CLOSE` programables).
   - Modos de fallo: `403` (proxy), `404` (backend), close `4033/4047/4074`, reconnect con `sid&ack` para validar reenvío de cola unacked.
2. **Tests `TunnelKit` (Swift Testing)**: `SshRelayFormatTests` (vectores C# + fuzz), `RelayStreamTests` (lectura/escritura/probe/reenvío), `EchoOverIapTests`, `HttpOverIapTests` (directo e indirecto vía `IapListener`).
3. **CI**: el mock corre en el runner macOS sin red (todo loopback). Sin secretos.
4. **Secuencia**: el mock completo se implementa con T-TUN-6 (M1) junto a `SshRelayFormat`; este M0 deja fijado el contrato (framing §REQ-TUN-2) y este plan.

## Contratos a validar en M1
- `CONNECT_SUCCESS_SID=1, RECONNECT_SUCCESS_ACK=2, DATA=4, ACK=7, LONG_CLOSE=10` big-endian.
- Reconnect ×2 con `sid&ack`; `MaxReadDataPerAck=1MB`; `ProbeConnectionAsync`.
