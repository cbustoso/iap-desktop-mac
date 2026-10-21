# Spec Azure (Bastion) — requirements (EARS)

Ref: `specs/azure/azure-bastion-research.md` (GH-84; §3.3 protocolo, §6.4 fases, §9 plan) ·
`specs/multitenant/requirements.md` (REQ-MT-1..6, perfiles aislados) ·
`specs/auth/requirements.md` (REQ-AUTH-*, patrón "sin secretos en el repo") · GH-86 (spike F0),
GH-87 (esta spec).

Decisión del dueño (2026-10-20): **Ruta 1 = túnel nativo en Swift**. Delegar en el `az` del
usuario queda como plan B, fuera de esta spec (research §3.5/§3.7).

## Terminología
- **Perfil Azure**: perfil (REQ-MT-1) con `provider = azure`: una cuenta Entra ID
  (`homeTenantId` + `oid`) con su refresh token en Keychain namespaced.
- **Tenant**: directorio Entra visible por la cuenta (`GET /tenants`).
- **Bastion apto**: `Microsoft.Network/bastionHosts` con `sku.name ∈ {Standard, Premium}` y
  `properties.enableTunneling == true` (research §3.1).
- **Sesión Bastion**: el triplete `{authToken, nodeId, websocketToken}` devuelto por
  `POST https://{dnsName}/api/tokens` (research §3.3).
- **Túnel**: un WebSocket `wss://{dnsName}/webtunnelv2/{websocketToken}?X-Node-Id={nodeId}`
  que transporta una conexión TCP lógica hacia la VM.

## REQ-AZ-1 — Login Entra ID sin secretos
- El sistema SHALL autenticar con OAuth 2.0 authorization code + PKCE (S256) contra
  `https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize|token`, con redirect
  loopback `http://localhost:{puerto efímero}` y navegador del sistema.
- El sistema SHALL pedir los scopes `openid profile offline_access
  https://management.core.windows.net//user_impersonation`.
- El sistema SHALL NOT embeber client ID ni secretos en el repo. El client ID SHALL venir de
  configuración del usuario (entorno, fichero local o UI), igual que el client de Google.
- WHERE el usuario elige "Iniciar sesión con código", el sistema SHALL usar device code
  (`/devicecode` + polling respetando `interval`).
- IF device code falla por Conditional Access THEN el sistema SHALL mostrar un mensaje
  específico ("tu organización bloquea este método") en lugar de un error genérico.
- IF el token endpoint devuelve `consent_required` THEN el sistema SHALL mostrar la URL de
  admin consent del tenant.

## REQ-AZ-2 — Tokens por tenant y aislamiento por perfil
- El sistema SHALL obtener access tokens por tenant con
  `POST /{tenantId}/oauth2/v2.0/token` (`grant_type=refresh_token`) y SHALL reemplazar el
  refresh token por el nuevo de cada respuesta.
- El sistema SHALL guardar solo el refresh token y metadatos no sensibles en Keychain bajo
  `ProfileStore.keychainService(for: id, suffix: "azure")`. Los access tokens SHALL vivir solo
  en memoria.
- Dos perfiles Azure abiertos a la vez SHALL NOT compartir tokens, cachés ni Keychain
  (extiende REQ-MT-3).
- WHEN se elimina un perfil Azure THEN `ProfileEnvironment.purge()` SHALL borrar su servicio
  `….azure`.
- IF el refresh falla con `invalid_grant` o `interaction_required` THEN el perfil SHALL
  pasar a "requiere Sign In" sin cerrar pestañas abiertas.

## REQ-AZ-3 — Descubrimiento ARM
- El sistema SHALL listar tenants → suscripciones (`state == Enabled`) → resource groups →
  VMs → NICs → Bastion hosts con las api-version de research §2, siguiendo `nextLink` hasta
  agotar la paginación.
- WHEN ARM responde 429 THEN el sistema SHALL reintentar respetando `Retry-After`, con un
  máximo de reintentos acotado.
- El sistema SHALL asociar cada VM a un Bastion por VNet (prefijo del `subnet.id` de su NIC).
  WHERE haya varios candidatos o una VNet peered, el usuario SHALL poder elegir el Bastion y
  la elección SHALL persistirse por VM en settings del perfil.
- El sistema SHALL requerir como mucho el rol Reader para descubrir y conectar (research §2.1).

## REQ-AZ-4 — Árbol Explorer Azure
- La ventana de un perfil Azure SHALL mostrar `Microsoft Azure → tenant → suscripción →
  resource group → VM`, con icono por SO y power state.
- Cada VM SHALL mostrar en Properties: Bastion asociado (nombre, SKU, `enableTunneling`),
  IP privada, RG, suscripción y tenant.
- IF la VM no tiene Bastion apto THEN Connect SHALL estar deshabilitado con el motivo
  ("SKU Basic sin Native Client", "sin Bastion en la VNet", …).

## REQ-AZ-5 — Túnel nativo (protocolo)
- Antes de abrir un túnel, el sistema SHALL leer el Bastion por ARM
  (`GET …/bastionHosts/{name}`, api-version ≥ `2024-01-01`) y SHALL rechazar los que no sean
  aptos sin llamar a `/api/tokens`.
- WHEN se abre una conexión THEN el sistema SHALL enviar `POST https://{dnsName}/api/tokens`
  con cuerpo `application/x-www-form-urlencoded` con exactamente `resourceId`,
  `protocol=tcptunnel`, `workloadHostPort` y `aztoken` (más `token` y la cabecera
  `X-Node-Id` si existe una sesión previa del mismo forwarder).
- El sistema SHALL abrir `wss://{dnsName}/webtunnelv2/{websocketToken}?X-Node-Id={nodeId}`
  con `Origin: https://{dnsName}`, **sin** `Sec-WebSocket-Protocol` y **sin**
  `Authorization`, y SHALL NOT enviar ningún mensaje inicial.
- El sistema SHALL transportar los bytes TCP como frames WebSocket **binarios** de hasta
  4096 B en sentido cliente→Bastion, y SHALL entregar al consumidor cada frame binario
  recibido tal cual.
- IF se recibe un frame de texto, o la respuesta del POST no contiene `authToken`, `nodeId`
  y `websocketToken` THEN el sistema SHALL fallar con `protocolChanged`.
- WHEN se cierra la última conexión de una sesión THEN el sistema SHALL enviar
  `DELETE https://{dnsName}/api/tokens/{authToken}` con `X-Node-Id` y SHALL tratar 404 como
  éxito.
- El sistema SHALL cerrar el WebSocket con código 1000 cuando el extremo local cierra, y
  SHALL cerrar el extremo local cuando el WebSocket se cierra.

## REQ-AZ-6 — Conexiones SSH, SFTP y RDP
- WHEN el usuario conecta por SSH a una VM Linux THEN el sistema SHALL abrir un túnel al
  puerto 22 (o el configurado) y SHALL ejecutar `SshSession` **in-process** sobre él
  (terminal y SFTP existentes), autenticando con llave o contraseña local de la VM y host key TOFU.
- WHEN el usuario conecta por RDP a una VM Windows THEN el sistema SHALL abrir un listener
  en `127.0.0.1:{efímero}` que acepte solo clientes loopback, SHALL generar un `.rdp` con
  `full address:s:127.0.0.1:{puerto}` y SHALL abrirlo con Windows App (`RDPBridge`).
- WHERE la VM tiene `AADLoginForWindows`, el sistema SHALL avisar de que el RDP con Entra
  no es posible desde macOS (research §3.6) y SHALL ofrecer credenciales locales o de dominio.
- WHEN se cierra la pestaña o la ventana del perfil THEN el sistema SHALL cerrar sus túneles
  y SHALL enviar los `DELETE` pendientes.

## REQ-AZ-7 — Errores tipados
- El sistema SHALL distinguir: `nativeClientDisabled(sku)`, `unauthorized(message)` (401/403),
  `targetNotFound` (404), `protocolChanged(status)`, `connectionLost(code)`, `timeout`.
- Cada error SHALL tener un mensaje accionable en la UI (research §9.3).

## REQ-AZ-8 — Secretos
- El sistema SHALL NOT escribir en logs, `description`, errores ni ficheros: el access token
  ARM (`aztoken`), `authToken`, `websocketToken`, refresh tokens, códigos de autorización ni
  `code_verifier`.
- El sistema SHALL NOT registrar la URL completa del WebSocket. Para correlacionar SHALL
  usar solo una huella no reversible (longitud + prefijo de SHA-256).

## REQ-AZ-9 — Red
- El sistema SHALL usar únicamente TCP 443 saliente hacia `login.microsoftonline.com`,
  `management.azure.com` y `{dnsName}` del Bastion.
- WHERE el sistema tenga proxy HTTP configurado, el túnel SHALL atravesarlo vía CONNECT
  (`ProxyConfig`, como IAP).

## REQ-AZ-10 — Verificación del protocolo no documentado
- Antes de cada release con soporte Azure, el equipo SHALL ejecutar la batería e2e contra un
  Bastion real (research §9.5, E1–E8) y SHALL registrar el resultado.
- El spike F0 (GH-86) SHALL demostrar, antes de implementar en `Sources/`: aceptación del
  token de la app registration propia, comportamiento con puerto custom, una sesión de más
  de 1 h y cierre limpio (`DELETE` 200/204 y después 404).
