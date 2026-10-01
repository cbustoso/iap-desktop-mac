# Spec RDP — requirements (EARS)

Ref: `docs/feature-parity.md` §6 (RDP) y §7 (credenciales Windows) · ADR-0003 ·
Linear CBU-48 (épica CBU-7).
Origen C#: `Google.Solutions.Terminal/Controls/{RdpClient,RdpClient.Marshalling,
RdpClient.ConnectionProperties,RdpExceptions}.cs`,
`Google.Solutions.IapDesktop.Extensions.Session/Protocol/Rdp/{RdpParameters,RdpContext,
RdpCredential,RdpCredentialCallback,WindowsUser}.cs`,
`Extensions.Session/ToolWindows/Session/RdpView.cs`,
`Apis/Compute/WindowsCredentialGenerator.cs`.

## REQ-RDP-1 — Vía principal: FreeRDP embebido
- El sistema SHALL implementar el renderer RDP principal en `RDPBridge` sobre
  **FreeRDP 3.x** embebido (SPM-C o XCFramework), con la sesión expuesta como una vista
  nativa (`NSView`) integrable en pestañas SwiftUI/AppKit (paridad `RdpClient` ActiveX →
  `NSView` propio, sin MSTSC en macOS — ver ADR-0003 §1).
- El sistema SHALL conectar FreeRDP contra `127.0.0.1:{puerto local}` del túnel abierto
  por `TunnelKit` (paridad: el original apunta al `IapListener` local), nunca directo al
  IP interno de la VM salvo transporte `.direct` explícito (REQ-RDP-2).
- El sistema SHALL soportar NLA/CredSSP (`RdpNetworkLevelAuthentication`), modo
  `RestrictedAdmin` (equivalente `mstsc /admin`, paridad `RdpSessionType.Admin`), y
  múltiples sesiones concurrentes en pestañas independientes.
- WHEN FreeRDP no está disponible o falla al inicializar (binario ausente, XCFramework
  no cargado) THEN el sistema SHALL degradar automáticamente a la vía de fallback
  (REQ-RDP-2) sin bloquear la conexión, registrando el motivo.

## REQ-RDP-2 — Fallback: `.rdp` generado + "Windows App"
- El sistema SHALL generar un archivo `.rdp` válido (formato Microsoft RDP, server
  `127.0.0.1:{puerto local del túnel}`, usuario/dominio, flags de redirección
  soportadas por el cliente externo) y abrirlo con `NSWorkspace.open(_:)` contra la
  app "Windows App" (antes "Microsoft Remote Desktop") cuando esté instalada.
- El sistema SHALL usar esta vía como **primera entrega de M2** (antes que FreeRDP
  embebido, paridad ADR-0003 §3: "fallback `.rdp` primero, embebido detrás de
  feature-flag") para desbloquear credenciales Windows + VM ops end-to-end sin esperar
  la integración FreeRDP.
- WHEN "Windows App" no está instalada THEN el sistema SHALL informar al usuario con un
  error tipado y un enlace de ayuda para instalarla (SHALL NOT fallar silenciosamente).
- El fallback SHALL NOT ofrecer pestañas integradas, `ConnectionBar` propio, ni control
  fino de redirecciones más allá de lo que el `.rdp`/cliente externo soporten (paridad
  ADR-0003 §2: "sin pestañas integradas ni control fino").
- Las credenciales SHALL pasarse al `.rdp` vía Keychain/prompt del sistema, nunca en
  texto plano embebido en el archivo (contraseña NO se persiste en el `.rdp` generado).

## REQ-RDP-3 — Parámetros RDP congelados (`RdpParameters`)
- El sistema SHALL definir un esquema de parámetros RDP con los mismos valores
  numéricos congelados que el original (persistidos como settings — ver
  `specs/settings/requirements.md` REQ-SET-5 — y compartidos por ambas vías, paridad
  ADR-0003 §3 "la spec fija los enums numéricos congelados... para que ambas vías
  compartan settings"):
  - `port: UInt16` (default 3389), `connectionTimeout` (default 30 s).
  - `connectionBar: {autoHide=0, pinned=1, off=2}` (default `autoHide`).
  - `authenticationLevel: {attemptServerAuth=0, requireServerAuth=1 (oculto en UI),
    noServerAuth=3}` (default `noServerAuth`, paridad: casi seguro falla con IAP salvo
    cert para "localhost").
  - `colorDepth: {highColor16=0, trueColor24=1, deepColor32=2}` (default `trueColor24`).
  - `audioPlayback: {playLocally=0, playOnServer=1, doNotPlay=2}` (default `playLocally`).
  - `audioInput: {disabled=0, enabled=1}` (default `disabled`).
  - `networkLevelAuthentication: {disabled=0, enabled=1}` (default `enabled`).
  - `automaticLogon: {enabled=0, legacyAbortOnFailure=1 (oculto), disabled=2}`
    (default `enabled`, salvo degradación por política local de guardado de
    contraseñas — ver REQ-RDP-7).
  - `redirectClipboard/Printer/SmartCard/Port/Drive/Device/WebAuthn: {disabled=0,
    enabled=1}` (defaults: clipboard=`enabled`, webAuthn=`enabled`, resto=`disabled`).
  - `hookWindowsKeys: {disabled=0, enabled=1, fullScreenOnly=2}` (default
    `fullScreenOnly`).
  - `restrictedAdminMode: {disabled=0, enabled=1}` (default `disabled`).
  - `sessionType: {user=0, admin=1}` (default `user`).
  - `dpiScaling: {disabled=0, enabled=1}` (default `enabled`).
  - `desktopSize: {legacyClientSize=0 (oculto), screenSize=1, autoAdjust=2}` (default
    `autoAdjust`).
- Los valores numéricos SHALL permanecer estables entre versiones (persistidos como
  settings); añadir un caso nuevo SHALL usar un valor numérico no reutilizado, nunca
  reasignar uno existente (paridad: "los valores no mapean a la interfaz RDP, pero deben
  mantenerse sin cambios porque se persisten como settings").
- Cada enum SHALL ser un tipo Swift congelado (sin `default:` que oculte casos no
  migrados), igual que los enums de `specs/ssh/` y `specs/settings/`.

## REQ-RDP-4 — Redirecciones (clipboard/drive/printer/audio/smartcard/device/WebAuthn)
- El sistema SHALL propagar a FreeRDP (vía principal) los flags de redirección activos
  del esquema (REQ-RDP-3) al establecer la sesión: clipboard, unidades locales,
  impresoras, tarjetas inteligentes, puertos COM/LPT, dispositivos Plug-and-Play,
  autenticadores WebAuthn/Windows Hello, y audio (reproducción local/remota/ninguna,
  entrada compartida sí/no).
- El fallback `.rdp` (REQ-RDP-2) SHALL traducir los mismos flags a las claves `.rdp`
  estándar de Microsoft (`redirectclipboard`, `drivestoredirect`,
  `redirectprinters`, `redirectsmartcards`, `redirectcomports`, `redirectposdevices`,
  `audiomode`, `audiocapturemode`, `camerastoredirect`/WebAuthn si el cliente lo soporta)
  en la medida en que el formato lo permita; donde no exista equivalente, el sistema
  SHALL omitir el flag sin fallar.
- Compartir dispositivos/unidades/impresoras SHALL requerir confirmación explícita del
  usuario la primera vez por instancia (paridad con el espíritu de "share" vs "don't
  share" del original, UX a definir en M2).

## REQ-RDP-5 — Pestañas, pantalla completa y connection bar
- El sistema SHALL soportar múltiples sesiones RDP simultáneas, cada una en su propia
  pestaña (paridad `SessionFactory`/`SessionViewBase`/`ClientViewBase`), reutilizando el
  patrón de pestañas de `SessionAreaView` ya usado por SSH (ver `specs/ssh/design.md`).
- El sistema SHALL soportar modo pantalla completa por sesión, con una barra de
  conexión (`ConnectionBar`) que respete el estado configurado
  (`autoHide`/`pinned`/`off`, REQ-RDP-3) y permita volver a modo ventana/cerrar sesión.
- WHEN el usuario redimensiona la ventana/pestaña y `desktopSize = autoAdjust` THEN el
  sistema SHALL re-negociar la resolución remota sin cerrar la sesión (paridad "auto
  resize"); si `desktopSize = screenSize`, el tamaño se fija al conectar y SHALL NOT
  cambiar durante la sesión.
- El sistema SHALL soportar un atajo de teclado para salir de pantalla completa
  (paridad `Ctrl+Alt+F11` del original; combinación exacta a definir en diseño de UI,
  sin bloquear esta spec).

## REQ-RDP-6 — Manejo de errores de conexión (incluye redirect RDSH / error 516)
- El sistema SHALL mapear los códigos de desconexión/fatal de FreeRDP a errores tipados
  con mensaje accionable, paridad con `RdpLogonException`/`RdpFatalException`/
  `RdpDisconnectedException` (tabla de códigos conocidos del original, reutilizable como
  referencia de mensajes).
- WHEN la desconexión reporta "Unable to establish a connection" (paridad código 516) Y
  el servidor remoto cambió de dirección respecto a la configurada THEN el sistema
  SHALL interpretarlo como una redirección de RD Session Host no soportada y SHALL
  mostrar un error tipado indicando que se use sesión `Admin` (`sessionType = admin`)
  en vez de `User` (paridad `RdsRedirectException`: "IAP Desktop no soporta redirects;
  cambia a sesión Admin").
- El fallback `.rdp` (REQ-RDP-2) SHALL propagar los errores que "Windows App" devuelva
  tal cual (el sistema no puede interceptar su UI), limitándose a verificar que el
  proceso se lanzó correctamente.

## REQ-RDP-7 — Credenciales Windows (reset vía API GCE, M2)
- El sistema SHALL implementar el reseteo de contraseña Windows vía metadata de la
  instancia (paridad `WindowsCredentialGenerator`, independiente del renderer RDP y
  entregado primero en M2 — ADR-0003 §"Consecuencias"):
  1. Generar un par RSA-2048 efímero (`SecKeyCreateRandomKey`, uso único, en memoria).
  2. Publicar en metadata `windows-keys` un payload `{userName, email,
     expireOn = now+5min, modulus, exponent, addToAdministrators, hashFunction=
     "sha256"}` (OAEP-SHA256; fallback a SHA1 solo si el agente del huésped es
     incompatible — paridad `DefaultEncryptionPadding = OaepSHA256`).
  3. Hacer poll de `getSerialPortOutput(port=4)` (con paginación `next?`) buscando una
     entrada que contenga `modulus` coincidente, con timeout configurable.
  4. Descifrar la contraseña recibida con la clave privada (`SecKeyCreateDecryptedData`,
     `.rsaEncryptionOAEPSHA256`) y producir `(username, password)`.
- El sistema SHALL requerir el permiso IAM `compute.instances.setMetadata`; si falta,
  SHALL fallar con error tipado antes de generar la llave (evitar coste innecesario).
- La contraseña resultante SHALL persistirse solo en Keychain (nunca en
  `UserDefaults`/logs, paridad REQ-SET-7 de `specs/settings/`), y SHALL exponerse a la
  UI "mostrar credenciales" solo bajo acción explícita del usuario.
- El reseteo SHALL ser independiente de la vía de renderizado elegida (FreeRDP o
  fallback `.rdp`): ambas consumen el mismo par usuario/contraseña resultante.

## REQ-RDP-8 — Seguridad y observabilidad
- El sistema SHALL NOT loguear contraseñas, llaves RSA efímeras, ni el contenido del
  `.rdp` generado (puede contener dominio/usuario, nunca contraseña en claro).
- El sistema SHALL verificar `authenticationLevel` por defecto en `noServerAuthentication`
  dado que IAP no emite certificados válidos para "localhost" (paridad comentario
  original: "likely to fail unless cert issued for localhost").

## Trazabilidad
REQ-RDP-1 → T-RDP-1,4 · REQ-RDP-2 → T-RDP-2 · REQ-RDP-3 → T-RDP-3 ·
REQ-RDP-4 → T-RDP-4,5 · REQ-RDP-5 → T-RDP-6 · REQ-RDP-6 → T-RDP-7 ·
REQ-RDP-7 → T-RDP-8 · REQ-RDP-8 → T-RDP-3,8,9.
