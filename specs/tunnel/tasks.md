# Spec Tunnel — tasks

- [ ] T-TUN-1 Spike transporte: NIO+WebSocketKit vs `Network.framework` (headers+proxy+subprotocolo). Entregable: decisión + `WebSocketTransport` mínimo. → REQ-1,4
- [ ] T-TUN-2 `SshRelayFormat` (5 tags big-endian + closes). Test: vectores portados de `TestSshRelayFormat` + fuzz. → REQ-2
- [ ] T-TUN-3 `RelaySession` + `RelayStream` (Sid/ACK/reconnect ×2/cola unacked/probe). Test: `TestSshRelayStream` portado + mock server. → REQ-2
- [ ] T-TUN-4 `IapClient` + `IapTarget` (URIs connect/reconnect, 403/404 tipados, User-Agent). Test: URIs + mapeo errores. → REQ-1
- [ ] T-TUN-5 `IapListener` + `PortFinder` + `TunnelPool` + `TunnelsView` modelo. Test: pool reutiliza, probe, retry puertos. → REQ-3
- [ ] T-TUN-6 Mock server IAP (port `WebSocketServer.cs`) + `TestEcho/HttpOverIap`. → todos (CBU-21)
- [ ] T-TUN-7 Fallback `gcloud` (P1). → REQ-5

Secuencia: T-TUN-1 → 2 → 6 → 3 → 4 → 5 → 7. Asignado: Claude Code (1–5), axet-code (6).
