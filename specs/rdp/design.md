# Spec RDP — design (`RDPBridge` + `TerminalUI`)

Ref: requirements.md · ADR-0003 · Origen C#: `Terminal/Controls/{RdpClient,
RdpClient.Marshalling,RdpExceptions}.cs`, `Extensions.Session/Protocol/Rdp/{RdpParameters,
RdpContext,RdpCredential,RdpCredentialCallback,WindowsUser}.cs`,
`Extensions.Session/ToolWindows/Session/RdpView.cs`, `Apis/Compute/
WindowsCredentialGenerator.cs`.

## Arquitectura (`RDPBridge`)

```
RdpParameters (enums congelados, compartidos con SettingsStore — specs/settings/)
  → RdpSessionFactory
        ├── FreeRdpRenderer   (vía principal: FreeRDP 3.x embebido, SPM-C/XCFramework)
        │     NSView bridged → pestaña SwiftUI/AppKit (reutiliza SessionAreaView)
        └── RdpFileFallback   (vía fallback: genera .rdp → NSWorkspace.open "Windows App")
  → sobre 127.0.0.1:{puerto} de TunnelKit (igual que SSHKit, no abre socket propio)

WindowsCredentialResetter (independiente del renderer, M2 primero)
  → GCPClient (metadata windows-keys + getSerialPortOutput) + Security.framework (RSA-2048)
  → Keychain (resultado username/password)
```

- `RDPBridge` NO decide por sí mismo directo vs túnel IAP: consume el mismo
  `TransportType` que settings (`specs/settings/design.md`, `SessionTransportType`,
  compartido con `SSHKit`) y recibe ya un `127.0.0.1:{puerto}` abierto por `TunnelKit`.
- `RdpSessionFactory` elige `FreeRdpRenderer` si está disponible y no hay feature-flag
  forzando el fallback; si falla la inicialización (binario ausente, XCFramework no
  cargado) degrada a `RdpFileFallback` sin bloquear la conexión (REQ-RDP-1).
- Orden de entrega (ADR-0003 §3): `RdpFileFallback` se implementa primero (M2, desbloquea
  credenciales + VM ops), `FreeRdpRenderer` llega detrás de un feature-flag.

## `RdpParameters` (enums congelados)

Mismos valores numéricos que el original (persistidos vía `SettingsStore`, ver
`specs/settings/design.md` "Esquema de settings"); viven en `RDPBridge` para que tanto
`FreeRdpRenderer` como `RdpFileFallback` los consuman sin duplicar:

```swift
public enum RdpConnectionBarState: Int, RawRepresentable, Sendable {
    case autoHide = 0, pinned = 1, off = 2
    public static let defaultValue = Self.autoHide
}
public enum RdpAuthenticationLevel: Int, RawRepresentable, Sendable {
    case attemptServerAuthentication = 0
    case requireServerAuthentication = 1   // oculto en UI, casi garantizado fallar
    case noServerAuthentication = 3
    public static let defaultValue = Self.noServerAuthentication
}
public enum RdpColorDepth: Int, RawRepresentable, Sendable {
    case highColor16 = 0, trueColor24 = 1, deepColor32 = 2
    public static let defaultValue = Self.trueColor24
}
public enum RdpAudioPlayback: Int, RawRepresentable, Sendable {
    case playLocally = 0, playOnServer = 1, doNotPlay = 2
    public static let defaultValue = Self.playLocally
}
public enum RdpAudioInput: Int, RawRepresentable, Sendable {
    case disabled = 0, enabled = 1
    public static let defaultValue = Self.disabled
}
public enum RdpNetworkLevelAuthentication: Int, RawRepresentable, Sendable {
    case disabled = 0, enabled = 1
    public static let defaultValue = Self.enabled
}
public enum RdpAutomaticLogon: Int, RawRepresentable, Sendable {
    case enabled = 0
    case legacyAbortOnFailure = 1   // oculto, no usar
    case disabled = 2
    public static let defaultValue = Self.enabled
}
// RdpRedirect{Clipboard,Printer,SmartCard,Port,Drive,Device,WebAuthn}: {disabled=0, enabled=1}
// defaults: Clipboard=.enabled, WebAuthn=.enabled, resto=.disabled
public enum RdpHookWindowsKeys: Int, RawRepresentable, Sendable {
    case disabled = 0, enabled = 1, fullScreenOnly = 2
    public static let defaultValue = Self.fullScreenOnly
}
public enum RdpRestrictedAdminMode: Int, RawRepresentable, Sendable {
    case disabled = 0, enabled = 1
    public static let defaultValue = Self.disabled
}
public enum RdpSessionType: Int, RawRepresentable, Sendable {
    case user = 0, admin = 1
    public static let defaultValue = Self.user
}
public enum RdpDpiScaling: Int, RawRepresentable, Sendable {
    case disabled = 0, enabled = 1
    public static let defaultValue = Self.enabled
}
public enum RdpDesktopSize: Int, RawRepresentable, Sendable {
    case legacyClientSize = 0   // oculto
    case screenSize = 1, autoAdjust = 2
    public static let defaultValue = Self.autoAdjust
}

public struct RdpParameters: Sendable {
    public var port: UInt16 = 3389
    public var connectionTimeout: TimeInterval = 30
    public var connectionBar: RdpConnectionBarState = .autoHide
    public var authenticationLevel: RdpAuthenticationLevel = .noServerAuthentication
    public var colorDepth: RdpColorDepth = .trueColor24
    public var audioPlayback: RdpAudioPlayback = .playLocally
    public var audioInput: RdpAudioInput = .disabled
    public var networkLevelAuthentication: RdpNetworkLevelAuthentication = .enabled
    public var automaticLogon: RdpAutomaticLogon = .enabled
    public var redirectClipboard: RdpRedirectClipboard = .enabled
    public var redirectPrinter: RdpRedirectPrinter = .disabled
    public var redirectSmartCard: RdpRedirectSmartCard = .disabled
    public var redirectPort: RdpRedirectPort = .disabled
    public var redirectDrive: RdpRedirectDrive = .disabled
    public var redirectDevice: RdpRedirectDevice = .disabled
    public var redirectWebAuthn: RdpRedirectWebAuthn = .enabled
    public var hookWindowsKeys: RdpHookWindowsKeys = .fullScreenOnly
    public var restrictedAdminMode: RdpRestrictedAdminMode = .disabled
    public var sessionType: RdpSessionType = .user
    public var dpiScaling: RdpDpiScaling = .enabled
    public var desktopSize: RdpDesktopSize = .autoAdjust
}
```

- Regla de evolución (paridad "los valores se persisten, nunca reasignar"): cualquier
  caso nuevo en estos enums SHALL recibir el siguiente `rawValue` libre, nunca reutilizar
  uno retirado; retirar un caso implica versión de esquema (`SettingsSchemaVersion`, ver
  `specs/settings/design.md`), no borrarlo del tipo si hay valores persistidos antiguos.

## Vía principal: `FreeRdpRenderer`

- Envuelve el cliente FreeRDP (contexto `freerdp_connect`/`rdp_client_new` vía binding
  C) en un objeto `Sendable`-friendly: la sesión real vive en un hilo/cola dedicada
  (paridad `RdpClient` ActiveX como control de UI con callbacks; aquí, un
  actor que serializa `connect/disconnect/resize/sendKeys` y expone eventos de salida
  vía `AsyncStream`).
- Traduce `RdpParameters` a las opciones FreeRDP equivalentes (NLA, `RestrictedAdmin`
  → `/admin`, `ColorDepth`, redirecciones `rdpdr`/`rdpsnd`/`cliprdr`, `DesktopSize` →
  resolución inicial + soporte de resize dinámico si `autoAdjust`).
- Expone una `NSView` (Metal/CoreGraphics backing del framebuffer FreeRDP) para
  integrarse en la pestaña (`SessionAreaView`, paridad con el patrón ya usado por SSH en
  `specs/ssh/design.md`).
- `KeyboardHookMode` (`hookWindowsKeys`) controla si combinaciones como Cmd+Tab/Win se
  capturan y reenvían al remoto, solo en pantalla completa cuando `fullScreenOnly`.

## Vía fallback: `RdpFileFallback`

- `RdpFileGenerator.makeFile(parameters:credential:localEndpoint:) -> URL`: serializa un
  `.rdp` (formato `clave:tipo:valor` de Microsoft) con, como mínimo: `full address`,
  `username`, `domain`, `audiomode`, `redirectclipboard`, `drivestoredirect`,
  `redirectprinters`, `redirectcomports`, `redirectposdevices`, `administrative session`
  (si `sessionType = admin`), `authentication level`, `enablecredsspsupport` (si NLA
  enabled). Flags sin equivalente `.rdp` se omiten (REQ-RDP-4).
- La contraseña NO se escribe en el `.rdp` (nunca en claro); el flujo delega en el
  prompt nativo de "Windows App" o en credenciales ya guardadas por el usuario en su
  propio llavero de Microsoft — `RDPBridge` solo pre-rellena usuario/dominio.
- `WindowsAppLauncher.open(_ fileURL: URL) throws`: usa `NSWorkspace.shared.open(_:)`
  resolviendo el bundle de "Windows App" (bundle identifier conocido); si no está
  instalada, lanza `RdpError.windowsAppNotInstalled` con `HelpTopic` (REQ-RDP-2).
- Sin pestaña integrada: "Windows App" gestiona su propia ventana; `RDPBridge` solo
  registra que la sesión fue lanzada (para la vista de sesiones activas de
  `ExplorerUI`), no controla su ciclo de vida interno.

## Pestañas, fullscreen y connection bar (solo vía FreeRDP)

- Reutiliza `SessionAreaView.openSession/closeSession` (igual que `TerminalUI` para SSH,
  `specs/ssh/design.md`): una pestaña por sesión RDP activa.
- `ConnectionBarView`: barra superpuesta en modo fullscreen con estado
  `autoHide`/`pinned`/`off`; botón para salir de fullscreen y cerrar sesión.
- Resize: si `desktopSize = autoAdjust`, el `NSView.boundsDidChange` dispara
  `FreeRdpRenderer.resize(width:height:)` (renegociación dinámica); si `screenSize`, el
  tamaño se fija una vez al conectar.
- Atajo de salida de fullscreen (paridad `Ctrl+Alt+F11`): mapeado a una combinación
  macOS razonable (p. ej. `⌃⌥⌘F`), definido en la capa de UI (`TerminalUI`/`ExplorerUI`),
  no bloqueante para esta spec.

## Manejo de errores (incluye redirect RDSH)

- `RdpError` tipado, con mapeo de los códigos de desconexión/fatal de FreeRDP a mensajes
  accionables (paridad tabla `RdpLogonException`/`RdpFatalException`/
  `RdpDisconnectedException`): `.logonFailed(code:message:)`, `.fatal(code:message:)`,
  `.disconnected(code:message:)`.
- `RdsSessionHostRedirectDetector`: si el código de desconexión corresponde a "Unable to
  establish a connection" (516) y la dirección del servidor cambió respecto a la
  configurada (paridad `IsRdsSessionHostRedirectionError`), el sistema traduce el error a
  `.rdsRedirectNotSupported` con mensaje "usa sesión Admin" (REQ-RDP-6).
- `RdpFileFallback` no intercepta errores internos de "Windows App"; solo verifica que
  `NSWorkspace.open` tuvo éxito y expone `.launchFailed` si no.

## Credenciales Windows (`WindowsCredentialResetter`, M2 primero)

- `WindowsCredentialResetter.reset(instance:username:addToAdministrators:) async throws
  -> (username: String, password: String)`:
  1. `SecKeyCreateRandomKey` RSA-2048 efímero (atributo `kSecAttrKeyType, kSecAttrKeySizeInBits`).
  2. `GCPClient.updateMetadata` añade entrada `windows-keys` con
     `{userName, email, expireOn: now+5min, modulus, exponent, addToAdministrators,
     hashFunction: "sha256"}` (base64 de los componentes de la llave pública).
  3. Poll `GCPClient.getSerialPortOutput(instance, port: 4, start: next)` con backoff
     hasta encontrar una línea que referencie el `modulus` enviado o hasta timeout
     (default alineado con `RdpParameters.connectionTimeout`-like, configurable).
  4. `SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, …)` sobre el
     payload cifrado recibido → contraseña en claro, envuelta inmediatamente en el tipo
     que persiste en Keychain (nunca `String` suelto más tiempo del necesario).
- Antes de generar la llave, verifica el permiso `compute.instances.setMetadata` (vía
  `GCPClient` IAM testIamPermissions) y falla con `.missingPermission` si no está.
- El resultado se entrega a `SettingsStore` (nivel Instancia, `RdpPassword` como
  `KeychainSettingsStore`, ver `specs/settings/design.md`) y queda disponible para
  ambas vías de renderizado sin relanzar el reseteo.

## Errores tipados
`RdpError.{freeRdpUnavailable, logonFailed(code:message:), fatal(code:message:),
disconnected(code:message:), rdsRedirectNotSupported, windowsAppNotInstalled,
launchFailed, missingPermission, credentialResetTimeout}` con `HelpTopic` donde aplique.

## Tests primero
Portar como tests unitarios: tabla de valores numéricos congelados de `RdpParameters`
(regresión si alguien reasigna un `rawValue`), generación de `.rdp` con distintas
combinaciones de redirecciones (snapshot del contenido serializado), detección de
redirect RDSH (`IsRdsSessionHostRedirectionError` con mocks de servidor cambiado/igual),
y el flujo completo de `WindowsCredentialResetter` con `GCPClient` mockeado (éxito,
timeout de polling, permiso faltante).
