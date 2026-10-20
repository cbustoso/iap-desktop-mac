# Spec Azure (Bastion) — tasks (→ issues GH)

Fases según research §6.4/§9.6. Cada tarea: dependencias, test y criterio verificable.

## F0 — Spike (GH-86)

- [ ] T-AZ-0 `Spikes/BastionSpike` (paquete SwiftPM independiente):
      - login PKCE con device code de fallback, client ID por `AZURE_CLIENT_ID`;
      - GET Bastion (ARM ≥ 2024-01-01), POST/DELETE `/api/tokens`, WS `/webtunnelv2`;
      - listener local con bombeo binario, modos `ssh` y `rdp` (`.rdp` temporal);
      - logs redactados; `instructions.md`; `scripts/validate-f0.sh`.
      Depende de: nada. Test: unitarios con servidor falso (form, headers WS sin subprotocolo
      ni Authorization, eco binario con troceo, texto → error, DELETE único, redacción).
      Criterio: `swift build` y `swift test` del spike en verde sin credenciales; con
      credenciales, A0.1–A0.6 (research §9.6) registrados en `specs/azure/f0-findings.md`.
      → REQ-AZ-5, 8, 10

## F1 — Identidad, ARM y árbol

- [ ] T-AZ-1 `CloudProvider` en `ProfileDescriptor` (decodifica `.gcp` por defecto) + "Nuevo
      perfil…" con elección de proveedor. Depende de: nada. Test: índice legado sin campo →
      `.gcp`; round-trip `.azure`. Criterio: tests de multitenant existentes en verde. → REQ-AZ-2
- [ ] T-AZ-2 `EntraAuthorizer` (PKCE + device code) + `EntraClientConfig` (client ID de
      entorno/fichero/UI, nunca embebido). Depende de: T-AZ-1. Test: `URLProtocol` stub de
      `/token` y `/devicecode` (pending → ok, expired, declined, `slow_down`), `state`
      inválido rechazado. Criterio: ningún secreto en `git grep`; el `description` de los
      tipos no contiene tokens. → REQ-AZ-1, 8
- [ ] T-AZ-3 `AzureCredentialFacade` (tokens por tenant, rotación de refresh token, Keychain
      `.azure`, `purge`). Depende de: T-AZ-2. Test: dos perfiles no comparten caché ni
      Keychain; `purge` borra `.azure`; refresh concurrente → 1 sola petición. Criterio: A1.3
      y A1.4. → REQ-AZ-2
- [ ] T-AZ-4 `AzureClient`: `AzureARMClient` (paginación, 429) + modelos. Depende de: nada.
      Test: fixtures de la REST reference, 3 páginas, 429 + `Retry-After`, sub `Disabled`
      omitida. Criterio: decodifica los ejemplos oficiales sin pérdida de los campos usados.
      → REQ-AZ-3
- [ ] T-AZ-5 `AzureDiscovery` + emparejado VM↔Bastion + elección manual persistida.
      Depende de: T-AZ-3, T-AZ-4. Test: VM en VNet con Bastion apto, con Bastion Basic, sin
      Bastion, peered con elección manual. Criterio: A1.5 y A1.6. → REQ-AZ-3, 4
- [ ] T-AZ-6 `ProfileSessionHosting` extraído de `ProfileSession`; `ProfileCoordinator`
      multi‑proveedor; esqueleto de `AzureProfileSession` (ventana, Sign In, carga). Depende
      de: T-AZ-1, T-AZ-5. Test: los tests de App/multitenant existentes en verde; un perfil
      Azure y uno GCP abiertos a la vez sin interferencia. Criterio: A1.7. → REQ-AZ-2, 4
- [ ] T-AZ-7 `ExplorerNode` con casos `azure*`, Properties y motivo de Connect deshabilitado.
      Depende de: T-AZ-4. Test: propiedades no vacías por nodo; motivo correcto por SKU.
      Criterio: `ExplorerUITests` en verde. → REQ-AZ-4

## F2 — Túnel nativo y conexión

- [ ] T-AZ-8 `TunnelKit`: `HandshakeProfile` en `NIOWebSocketTransport` (`.iap` / `.bastion`)
      y path sin decodificar. Depende de: nada. Test: `TunnelKitTests` existentes sin cambios
      en verde; el handshake `.bastion` no lleva `Sec-WebSocket-Protocol` ni `Authorization`.
      Criterio: A2.5. → REQ-AZ-5
- [ ] T-AZ-9 `BastionKit`: `BastionSessionClient` + `BastionTunnelStream` + `BastionTestSupport`
      (servidor falso portado del spike). Depende de: T-AZ-0 (F0 verde), T-AZ-8. Test:
      research §9.5 puntos 1, 2 y 5. Criterio: A2.1. → REQ-AZ-5, 7, 8
- [ ] T-AZ-10 `BastionLocalForwarder` + conexión SSH/SFTP in-process + RDP vía Windows App
      en `AzureProfileSession`. Depende de: T-AZ-6, T-AZ-9. Test: research §9.5 puntos 3 y 4
      (SSH real contra `MockSSHServer` a través del servidor falso). Criterio: A2.2–A2.4 (e2e
      E1, E2, E3, E6, E7, E8). → REQ-AZ-6

## F3 — Endurecimiento

- [ ] T-AZ-11 Proxy CONNECT para `/api/tokens` (URLSession con proxy del sistema) y para el WS
      (`ProxyConfig`). Depende de: T-AZ-10. Test: proxy CONNECT local en test. Criterio: A3.2.
      → REQ-AZ-9
- [ ] T-AZ-12 Sesiones largas y multi‑pestaña: re‑POST encadenado (`token` + `X-Node-Id`),
      aviso de `connectionLost`. Depende de: T-AZ-10. Test: servidor falso que corta a los N
      segundos. Criterio: A3.1 (E4, E5). → REQ-AZ-5, 7
- [ ] T-AZ-13 `docs/usage.md` §13 Azure (app registration, admin consent, SKU, RBAC, costos,
      límite de RDP con Entra) + checklist e2e pre‑release. Depende de: T-AZ-10. Criterio:
      A3.3. → REQ-AZ-10
- [ ] T-AZ-14 Inyección de `protocolChanged` (respuesta alterada en el servidor falso) y su
      mensaje en la UI. Depende de: T-AZ-9. Criterio: A3.4. → REQ-AZ-7

## Fuera de alcance (no crear issues salvo decisión del dueño)
Plan B `AzCliBastionTunnel`, SSH con Entra, `runCommand`, IP‑connect, SKU Developer, Arc,
modo "Direct".
