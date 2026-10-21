# Spec Azure (Bastion) — design

Ref: `requirements.md` · `azure-bastion-research.md` (§3.3 protocolo con permalinks,
§5 diseño, §9 plan) · `specs/multitenant/design.md` · `specs/tunnel/transport-decision.md`.

## Decisión: túnel nativo Swift, composición sobre lo existente

El soporte Azure se suma **por composición**, como GH-72: un `AzureProfileSession` por perfil
Azure, con su propio grafo de objetos. SSH/SFTP/terminal/RDP se reutilizan sin cambios
internos. Las piezas nuevas son la identidad (Entra), el descubrimiento (ARM) y el transporte
(Bastion).

```
ProfileCoordinator
  ├── ProfileSession            (provider = gcp, sin cambios funcionales)
  └── AzureProfileSession       (provider = azure, nuevo)
        ├── AzureCredentialFacade   (AuthKit)    Keychain …profile.<id>.azure
        ├── AzureDiscovery          (AzureClient) → AzureARMClient
        ├── BastionTunnelFactory    (BastionKit)  → BastionSessionClient + BastionTunnelStream
        ├── BastionLocalForwarder   (BastionKit)  solo RDP
        ├── TerminalTabManager / SftpBrowsers / RdpFallbackConnector (existentes)
        └── ExplorerWindowController(dataSourceLabel: "Azure")
```

## Módulos y dependencias (Package.swift raíz, al implementar F1/F2)

| Target | Depende de | Contenido |
|---|---|---|
| `AuthKit` (existente) | — | + `CloudProvider`, `EntraClientConfig`, `EntraAuthorizer`, `AzureCredentialFacade`, `AzureOfflineCredential` |
| `AzureClient` (nuevo) | — (Foundation) | `AzureARMClient`, `Page<T>`, modelos (`AzureTenant`, `AzureSubscription`, `AzureVM`, `AzureNIC`, `AzureBastion`), `AzureDiscovery` |
| `BastionKit` (nuevo) | `TunnelKit`, `SSHKit` (por `SshByteStream`), NIO | `BastionSessionClient`, `BastionTunnelStream`, `BastionLocalForwarder`, `BastionTunnelError` |
| `TunnelKit` (existente) | — | `NIOWebSocketTransport` parametrizado con `HandshakeProfile` (`.iap(token)` / `.bastion(dnsName)`); IAP sin cambios de comportamiento |
| `ExplorerUI` (existente) | + `AzureClient` (solo modelos) | nodos `azure*` en `ExplorerNode` |
| `App` (existente) | + `AzureClient`, `BastionKit` | `ProfileSessionHosting`, `AzureProfileSession` |
| `BastionTestSupport` (nuevo, solo tests) | NIO HTTP1/WebSocket | servidor falso `/api/tokens` + `/webtunnelv2` (portado del spike `Spikes/BastionSpike`) |

## Identidad (REQ-AZ-1, 2)

- `EntraAuthorizer` reutiliza `PKCE`, `LoopbackReceiver` y `LoginSession` de AuthKit. La
  redirect es `http://localhost:{port}`, sin path (Entra ignora el puerto en localhost).
- Device code: `POST /organizations/oauth2/v2.0/devicecode` → `DeviceCodePrompt` en la UI →
  polling con `interval` (más 5 s ante `slow_down`) hasta `expires_in`.
- `AzureCredentialFacade` (actor): `[tenantID: (token, expiry)]`. Refresca con 5 min de
  margen y serializa el refresh por tenant con un `Task` compartido.
- Persistencia: `AzureOfflineCredential { homeTenantID, objectID, username, refreshToken }`,
  cuenta Keychain `<homeTenantID>:<oid>`.
- `ProfileDescriptor` gana `provider: CloudProvider` (decodifica `.gcp` si falta, sin
  migración de datos).

## Descubrimiento (REQ-AZ-3, 4)

- `AzureARMClient.list<T>(path:apiVersion:tenantID:)` sigue `nextLink` literal. Ante 429
  aplica backoff con `Retry-After`, como mucho 3 reintentos.
- `AzureDiscovery.load()`:
  - `tenants()` → por tenant `subscriptions()` → por sub (`TaskGroup`, máx. 4) `resourceGroups`,
    `virtualMachines`, `bastionHosts`;
  - NICs bajo demanda: al expandir el RG, o en bloque con
    `GET /subscriptions/{sub}/providers/Microsoft.Network/networkInterfaces` (⚠️ api-version
    `2026-01-01` a confirmar en F1).
- Emparejado VM↔Bastion: `vnetID(of: subnetID)` = prefijo hasta `/subnets/`. Bastion de la
  VNet = el que tiene `ipConfigurations[].subnet.id` con ese prefijo. Elección manual
  guardada en `SettingsStore` del perfil (`azure.bastion.<vmID>`).

## Transporte (REQ-AZ-5, 7, 8, 9)

Protocolo normativo: research §3.3 (permalinks a `tunnel.py` L80‑230).

```
BastionSessionClient.open(dnsName, vmID, port, armToken, previous?) ─POST /api/tokens─▶ Session{authToken,nodeId,websocketToken}
BastionTunnelStream.open(target, session)  ─WSS /webtunnelv2/{ws}?X-Node-Id─▶ (binario ⇄)
BastionSessionClient.close(dnsName, session) ─DELETE /api/tokens/{authToken}─▶ 200|204|404
```

- `BastionTunnelStream` conforma `SshByteStream`: `write` trocea en frames binarios de
  4096 B; `read` devuelve cada frame binario, o `nil` ante Close; los frames de texto producen
  `protocolChanged`.
- El path del WS se pasa **sin decodificar** a WebSocketKit (`connect(scheme:host:port:path:query:)`),
  para no alterar `websocketToken` (`URL.path` decodifica escapes `%`).
- Cierre: `close()` envía Close 1000 (WebSocketKit usa `goingAway` por defecto, así que el
  código se pasa explícito).
- `BastionLocalForwarder` (RDP): NIO `ServerBootstrap` en `127.0.0.1:0` con `NIOAsyncChannel`.
  Por cada hijo: `open` encadenando la sesión previa → `BastionTunnelStream` → dos tareas de
  bombeo. Mantiene un contador de activos y, al llegar a 0, hace `DELETE` de la última sesión.
  Rechaza peers no loopback.
- SSH in-process: `SshSession.connect(over: BastionTunnelStream)`, sin listener.
- Redacción: `Secret` (wrapper) con `description` = `‹redacted len=N sha256=xxxxxxxx›`. Los
  tokens viajan siempre envueltos hasta el punto exacto de uso (cuerpo del POST o path del WS).

## Conexiones (REQ-AZ-6)

- SSH/SFTP: credencial de la VM (usuario + llave o contraseña) en `KeychainSettingsStore` del
  perfil, con alcance `azure.vm.<id>`. Host key: `InMemoryKnownHosts` → T-SSH-7.
- RDP: `RdpFallbackConnector.connect(target: 127.0.0.1:<forwarder.port>)`. El `.rdp` y
  Windows App ya están resueltos en `RDPBridge`.
- Aviso Entra RDP: si `instanceView.extensions` contiene `AADLoginForWindows`.

## Errores → UI (REQ-AZ-7)

Tabla normativa en research §9.3. La detección de SKU no apto ocurre antes de la red de datos
(datos ARM), así que E8 no genera POST.

## Verificación (REQ-AZ-10)

- F0 (GH-86): `Spikes/BastionSpike`, paquete SwiftPM independiente (no toca el
  `Package.swift` raíz), con `scripts/validate-f0.sh` para A0.1–A0.5.
- CI: tests unitarios con servidor falso (sin red).
- Pre‑release: batería e2e manual E1–E8 (research §9.5).

## Fuera de alcance
Plan B `az` (research §3.5), SSH con Entra, `runCommand`, IP‑connect, SKU Developer
(`/omni/webtunnel`), Arc, modo "Direct" (GH-84.14).
