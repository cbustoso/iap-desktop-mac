# Spec SSH Close — design

Ref: requirements.md · Código existente leído (sin modificar):
`Sources/ExplorerUI/SessionAreaView.swift`, `Sources/ExplorerUI/SessionTabHosting.swift`,
`Sources/TerminalUI/TerminalTabManager.swift`, `Sources/TerminalUI/TerminalSessionView.swift`,
`Sources/App/App.swift` (menú, `wireSshConnect`), `Sources/App/SftpBrowse.swift`.

## Resumen del cambio

No se crea módulo nuevo: se extiende `SessionAreaView` (botón `×` por pestaña),
`SessionTabHosting` (nuevo método de consulta), `TerminalTabManager` (confirmación +
heurística de actividad delegada a un closure) y el cableado de menú/`NSResponder` en
`Sources/App/App.swift`. Todo el trabajo cae en `ExplorerUI`, `TerminalUI` y `App`; no
toca `SSHKit` (ya expone `isConnected`/`close()`) ni `TunnelKit`.

## 1. Botón `×` por pestaña (`SessionAreaView`)

```
SessionAreaView (NSTabView)
  cada NSTabViewItem con identifier == instanceID de una sesión SSH
    → `view` del tab label: NSStackView [ NSTextField(label) , NSButton(×, borderless) ]
      en vez de un `NSTabViewItem.label` plano.
```

- `NSTabView` no soporta nativamente un botón de cierre por pestaña: la solución SHALL
  ser una vista de etiqueta personalizada asignada vía la API no pública habitual
  (`NSTabViewItem` no expone `view` para la etiqueta directamente en todas las
  versiones) **o**, alternativa más simple y robusta, sustituir `label` dinámico por
  `attributedLabel`/trackeo de hover a nivel de `NSTabView` subclassed que dibuje el `×`
  cuando el mouse está sobre el tab (`mouseMoved`/`cursorUpdate` + `hitTest` sobre el
  rect del `×`). Se deja como decisión de implementación entre ambas variantes (ambas
  cumplen REQ-CLOSE-1); cualquiera SHALL exponer un callback
  `onCloseRequested: (String) -> Void` que `SessionAreaView` invoca con el
  `identifier` del tab pulsado.
- `SessionTabHosting` (protocolo) SHALL ganar:
  ```swift
  var onCloseRequested: ((String) -> Void)? { get set }
  ```
  (property closure, mismo patrón que `onConnectRequest`/`onVmControlRequest` ya usados
  en `ExplorerWindowController`), para que `App` (que no conoce `AppKit` de bajo nivel)
  conecte la UI con `TerminalTabManager`.
- Solo las pestañas con identifier presente en `TerminalTabManager.openInstanceIDs`
  disparan la ruta de cierre SSH (REQ-CLOSE-3/4); las de Files/RDP usan su propio
  manejador ya existente (`SftpBrowsers.close`, futuro RDP) — `App` enruta por tipo de
  pestaña, `SessionAreaView` no distingue el tipo, solo reenvía el `identifier`.

## 2. Atajo `⌘W` (reasignación contextual)

- El ítem de menú `File → Close Window` (`Sources/App/App.swift:333`) deja de ser el
  único consumidor de `⌘W`. Patrón AppKit estándar (igual que Xcode/Safari/Terminal):
  el `NSMenuItem` sigue existiendo con el mismo `keyEquivalent "w"`, pero su `action`
  pasa a un selector propio en `AppDelegate`/`ExplorerWindowController`
  (`closeActiveSessionOrWindow(_:)`) en vez de `NSWindow.performClose(_:)` directo:
  ```swift
  @objc func closeActiveSessionOrWindow(_ sender: Any?) {
      if let activeID = windowController.sessionTabs.selectedSessionIdentifier,
         terminalTabs?.openInstanceIDs.contains(activeID) == true {
          requestCloseSession(instanceID: activeID)   // REQ-CLOSE-3/4
      } else {
          window?.performClose(sender)                 // comportamiento actual
      }
  }
  ```
- `validateMenuItem`/`NSMenuItemValidation` SHALL mantener el título "Close Window"
  cuando no hay pestaña de sesión activa, y SHALL NOT cambiar el texto a "Close Tab"
  dinámicamente en v1 (simplicidad; es una mejora de UX opcional fuera de esta spec) —
  el comportamiento (qué cierra) es lo que cambia, no necesariamente el label, aunque
  se recomienda renombrar el ítem a algo neutro como "Close" si el equipo de diseño lo
  aprueba (no bloqueante).

## 3. Confirmación (`SessionCloseConfirmer`)

```swift
@MainActor
struct SessionCloseConfirmer {
    // Inyectado por tests; en producción consulta `FileBrowserViewModel.transfers`
    // (vía SftpBrowsers) y el timestamp de última salida del `TerminalBackend`.
    var hasActiveTransfer: (String) -> Bool          // instanceID -> hay transferencia Files en curso
    var recentOutputWithinWindow: (String) -> Bool   // instanceID -> heurística REQ-CLOSE-3.2
    var window: Duration = .seconds(2)

    func isActive(instanceID: String) -> Bool {
        hasActiveTransfer(instanceID) || recentOutputWithinWindow(instanceID)
    }
}
```

- `TerminalTabManager` (o un pequeño coordinador en `App`, p. ej.
  `SshSessionCloseCoordinator`, para no mezclar lógica de `AppKit`/`NSAlert` dentro de
  `TerminalUI`, que hoy es agnóstico de diálogos) SHALL:
  1. Consultar `SessionCloseConfirmer.isActive(instanceID:)`.
  2. Si `true`: mostrar `NSAlert` (sheet si la ventana es visible, modal si no — mismo
     patrón que `ExplorerWindowController.confirm`), `messageText = "¿Cerrar
     <título>?"`, `informativeText = "Hay actividad en curso en esta sesión."`.
  3. Si el usuario confirma (o no hacía falta preguntar): invocar
     `TerminalTabManager.close(instanceID:)` (ya existente, sin cambios).
- `TerminalSessionView`/`TerminalBackend` SHALL exponer el timestamp de la última
  recepción de datos (`lastOutputAt: Date?`, actualizado en el mismo punto donde hoy se
  llama `terminalView.feed(text:)`) para que `recentOutputWithinWindow` pueda
  implementarse sin acoplar `TerminalUI` a `NSAlert`/`App`.

## 4. Limpieza (reutiliza lo existente, sin romper la regla de sesión compartida)

```
SshSessionCloseCoordinator.requestClose(instanceID)
  → SessionCloseConfirmer.isActive(instanceID)?
      sí → NSAlert → cancelado? return : continuar
      no → continuar
  → TerminalTabManager.close(instanceID)      // ya existe: cierra canal + quita pestaña
       → onSessionEnded(instanceID)            // ya cableado en wireSshConnect
            → sshSessions.removeValue(instanceID)
            → if sftpBrowsers.isUsing(session) { return }   // ya existe: no cierra la sesión compartida
            → session.close()                                // SshSession.close() → libera el stream de TunnelKit
```

- No se modifica `wireSshConnect` ni `SftpBrowsers.isUsing`: ya implementan exactamente
  la regla de REQ-CLOSE-4.3 (sesión compartida con Files no se cierra). Esta spec solo
  añade la ruta de **invocación manual** (`×`/`⌘W`) que hoy no existe; la lógica de
  limpieza de abajo (`TerminalTabManager.close` → `onSessionEnded`) ya está entregada.
- Idempotencia (REQ-CLOSE-4, "cerrar dos veces"): ya cubierta por el `guard let view =
  views.removeValue(...)` de `TerminalTabManager.close` (si ya se quitó, no hace nada
  más) y por el `markEnded()` con `guard !hasEnded` de `TerminalSessionView`.

## 5. Cerrar la ventana cierra todo (`windowShouldClose`)

- `ExplorerWindowController` SHALL implementar `NSWindowDelegate.windowShouldClose(_:)`
  (hoy no lo hace: la ventana se cierra sin interceptar). Flujo:
  ```swift
  func windowShouldClose(_ sender: NSWindow) -> Bool {
      let activeSessions = terminalTabs?.openInstanceIDs.filter(confirmer.isActive) ?? []
      guard !activeSessions.isEmpty else {
          closeEverythingAndAllow()   // sin diálogo, cierre inmediato
          return true
      }
      presentAggregateConfirmation(count: activeSessions.count) { confirmed in
          guard confirmed else { return }
          self.closeEverythingAndAllow()
          sender.close()   // reintenta el cierre ya confirmado
      }
      return false   // bloquea el primer intento hasta que el usuario responda
  }

  private func closeEverythingAndAllow() {
      sftpBrowsers?.closeAll()                 // ya existe
      Task { await terminalTabs?.closeAll() }  // ya existe
  }
  ```
- El diálogo agregado (REQ-CLOSE-5) SHALL mostrarse **una sola vez** con un recuento
  ("Hay N sesiones con actividad. ¿Cerrar la ventana de todos modos?"), no un `NSAlert`
  por pestaña — evita el "alert storm" clásico de cerrar una ventana con muchas
  pestañas abiertas.
- Como `windowShouldClose` es síncrono y la limpieza (`closeAll()`) es `async`, la
  primera llamada SHALL devolver `false` y, tras completar la limpieza (o tras la
  confirmación del usuario), SHALL invocar `sender.close()` de nuevo — en ese segundo
  intento ya no quedan sesiones activas por confirmar (se cerraron), así que
  `windowShouldClose` SHALL devolver `true` directamente. Esto evita bloquear el hilo
  principal esperando una `Task` dentro de un método que AppKit espera síncrono.

## Errores / casos límite
- Ventana cerrada mientras una confirmación de pestaña individual (REQ-CLOSE-3) está
  pendiente: el `NSAlert` de pestaña individual, al ser sheet de la misma ventana, SHALL
  cancelarse implícitamente si la ventana desaparece (comportamiento estándar de
  `NSAlert.beginSheetModal`); no requiere manejo especial.
- Cerrar la última pestaña de sesión (vacía `SessionAreaView`) SHALL mostrar el
  empty-state existente, SHALL NOT cerrar la ventana por sí sola (solo `windowShouldClose`
  explícito la cierra).
