# Comparativa IAP Desktop (Windows) vs IAP Desktop Mac — 2026-10-14

Método: REA 6.5.0 (instalado global, `rea-agents`) + diff estático del MSI oficial v2.50.1825 + 3 análisis fuente C#↔Swift.
Límites REA: sin motores nativos (Ghidra/Hopper/IDA ausentes) → sin decompilación; sí sirvieron inventario de endpoints del binario, captura AX (`capture-native-ui-scenario`, window 38174) e inspección.

## 1. Nivel wire/protocolo — PARIDAD ALTA
- Túnel: `wss://tunnel.cloudproxy.app/v4/`, `mtls.` variant, subprotocolo `relay.tunnel.cloudproxy.app`, `Origin: bot:iap-tunneler` — idénticos.
- Framing SSH Relay v4: tags y closes idénticos; 2 divergencias intencionales documentadas (ACK 64-bit vs truncado C#, validación estricta vs Debug.Assert).
- OAuth: mismos endpoints + PKCE; sin verificación de firma JWT en ambos (decisión original, no gap).
- Ausentes con causa: batch API (rendimiento), Analytics (omisión deliberada), `secureconnect` (sin equivalente macOS), PSC Host-trick (Windows-only).

## 2. Gaps por severidad (veredicto agentes + verificación)
### Críticos
1. **RDP ignora settings efectivos** — `RdpConnectFlow.connect` usa `RdpParameters()` por defecto; lo editado no llega al `.rdp`.
2. **Filtro agregado inventario invertido** — `!= .windows` vs `OperatingSystems.Windows` del original.
3. **Esquema Settings 9/40** — enums existen pero la UI no los edita ni persisten.
### Altos (selección)
- Estados lifecycle colapsados (sin terminated/suspended → VM-ops sin gating); NLA desacoplada; RDSH-516 sin detector; AD-Join ausente; workforce-cert OS Login ausente; validación ACK ausente (fail-open); cierre anormal sin close frame tratado como limpio; SSH sin keepalive de nivel; EventLog aplanado (sin categorías/tipos); prioridad metadata instancia-vs-proyecto invertida; OAuth sin mTLS/PSC en `/token`; reauth global `invalid_grant` ausente; login_hint/minimal-flow ausente.
### Mejoras nuestras (superset)
- Host key TOFU (el original no verifica), SFTP con seek/reanudación (el original no puede), multi-perfil (el original: un perfil), epoch anti-race en splice, redacción en logs.

## 3. UI (evidencia REA AX, 453 nodos)
Estructura Project Explorer + outline + tabs verificada contra la captura. Sin renderer RDP embebido (decisión ADR-0003: fallback Windows App).
