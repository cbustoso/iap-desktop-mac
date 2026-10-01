# Spec RDP — tasks (→ issues Linear)

- [ ] T-RDP-1 `RdpFileFallback`: `RdpFileGenerator` (serializa `.rdp` desde
      `RdpParameters` + credencial, sin contraseña en claro) + `WindowsAppLauncher`
      (`NSWorkspace.open`, detecta "Windows App" ausente). Depende de: T-RDP-3 (enums).
      Test: snapshot de `.rdp` generado para combinaciones de redirecciones; error
      tipado si "Windows App" no está instalada. Criterio: cero contraseña en el
      archivo generado. → REQ-2,4
- [ ] T-RDP-2 Integración M2 del fallback end-to-end: lanzar `.rdp` contra
      `127.0.0.1:{puerto}` de `TunnelKit`, con credenciales resueltas por T-RDP-8.
      Depende de: T-RDP-1, T-RDP-8, `TunnelKit` (ya entregado). Test: integración con
      mock de túnel local + `GCPClient` mockeado. Criterio: entrega M2 sin esperar
      FreeRDP. → REQ-1,2
- [ ] T-RDP-3 `RdpParameters` + enums congelados (connectionBar, authenticationLevel,
      colorDepth, audioPlayback/Input, NLA, automaticLogon, redirect*, hookWindowsKeys,
      restrictedAdminMode, sessionType, dpiScaling, desktopSize) con `rawValue`
      estables. Depende de: nada. Test: assert de valores numéricos congelados (tabla
      1:1 con el original) + regresión si se reasigna un caso. Criterio: ningún enum
      usa `default:` que oculte un caso no migrado. → REQ-3,8
- [ ] T-RDP-4 `FreeRdpRenderer` (binding FreeRDP 3.x vía SPM-C/XCFramework: connect,
      NLA/CredSSP, RestrictedAdmin, framebuffer → `NSView`). Depende de: T-RDP-3.
      Test: spike de conexión contra servidor RDP de prueba o mock; traducción de cada
      parámetro de `RdpParameters` a la opción FreeRDP equivalente. Criterio: feature-flag
      para activar/desactivar sin afectar al fallback. → REQ-1
- [ ] T-RDP-5 Redirecciones en `FreeRdpRenderer` (clipboard/drive/printer/smartcard/
      port/device/WebAuthn/audio). Depende de: T-RDP-4. Test: cada flag activo se
      traduce al canal FreeRDP correspondiente (`rdpdr`/`rdpsnd`/`cliprdr`); flags en
      `disabled` no abren el canal. → REQ-4
- [ ] T-RDP-6 Pestañas + fullscreen + `ConnectionBarView` (reutiliza
      `SessionAreaView.openSession/closeSession`); resize dinámico si
      `desktopSize=autoAdjust`, tamaño fijo si `screenSize`. Depende de: T-RDP-4. Test:
      UI test de apertura/cierre de pestaña, resize dispara
      `FreeRdpRenderer.resize`, `screenSize` no cambia tras conectar. → REQ-5
- [ ] T-RDP-7 Manejo de errores (`RdpError` + mapeo de códigos FreeRDP +
      `RdsSessionHostRedirectDetector` para error 516 con servidor redirigido).
      Depende de: T-RDP-4. Test: tabla de códigos conocidos → mensaje; caso 516 con
      servidor igual (no redirect) vs distinto (sí redirect) → `.rdsRedirectNotSupported`.
      → REQ-6
- [ ] T-RDP-8 `WindowsCredentialResetter` (RSA-2048 efímero, metadata `windows-keys`,
      poll `getSerialPortOutput`, decrypt OAEP-SHA256) usando `GCPClient` mockeado.
      Depende de: nada (paralelizable con T-RDP-1..7). Test: éxito end-to-end mockeado,
      timeout de polling, permiso `compute.instances.setMetadata` faltante → error
      tipado antes de generar la llave. Criterio: resultado solo llega a
      `KeychainSettingsStore`, nunca a `UserDefaults`/logs. → REQ-7,8
- [ ] T-RDP-9 Redacción de secretos en OSLog (contraseñas, llaves RSA efímeras,
      contenido de `.rdp`) + auditoría "sin contraseñas en logs", paridad `T-AUTH-9`/
      `T-SET-10`. Depende de: T-RDP-1, T-RDP-8. Test: assert sobre formateo/dump. →
      REQ-8

Secuencia: T-RDP-3 → T-RDP-1 → T-RDP-2 (fallback M2, prioridad); T-RDP-8 en paralelo
desde el inicio (M2, bloquea T-RDP-2); T-RDP-3 → T-RDP-4 → (T-RDP-5 ∥ T-RDP-6 ∥ T-RDP-7)
para la vía FreeRDP (detrás de feature-flag, posterior a M2); T-RDP-9 al cierre de
T-RDP-1 y T-RDP-8.
