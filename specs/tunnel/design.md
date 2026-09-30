# Spec Tunnel — design (`TunnelKit`)

```
IapClient ─→ IapTarget (connect/reconnect URIs)
  ─→ RelaySession (Sid, reconnect ×2) ─→ RelayStream (unacked queue, resend, probe)
  ─→ WebSocketTransport (NIO + WebSocketKit) ─→ IapListener (NWListener loopback)
  ─→ TunnelPool (actor, Profile→Task<Tunnel>) → 127.0.0.1:port
```

- `SshRelayFormat`: `encode/decode` big-endian para los 5 tags; fuzz-test contra vectores C# (`TestSshRelayFormat`).
- `RelaySession`/`RelayStream`: actores; `ExpectedAck/UnackedCount`; `probe(timeout)`; `resendUnacked()`.
- `WebSocketTransport`: controla headers (`Authorization/Origin/User-Agent/Subprotocol`), proxy CONNECT, keepalive ping 60 s. Decisión NIO+WebSocketKit por defecto; `Network.framework` solo si el spike demuestra upgrade WS estable (documentar en PR).
- `IapListener`: `NWListener(tcp, 127.0.0.1:{port})`, `isClientAllowed` (loopback + UID), relay bidireccional `AsyncSequence`, `NetworkStatistics` (bytes up/down, fecha).
- `TunnelPool`: `Dictionary<Profile, Task<Tunnel>>`, ref-count, `probe` antes de `listen`, `PortFinder` determinista (hash FNV proyecto/zona/nombre/puerto → rango 10000–60000, +5 reintentos).
- Errores: `TunnelError.{denied, backendNotFound, relayClosed(code), reconnectExhausted, portDenied, proxyBlocked}` con `HelpTopic` (firewall IAP, IAM, proxy).
- Tests primero: mock WebSocket server (port de `Util/WebSocketServer.cs`) → `TestSshRelayFormat/Stream`, `TestEchoOverIap`, `TestHttpOverIap`.
