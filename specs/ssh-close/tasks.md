# Spec SSH Close — tasks (→ issues Linear/GH)

- [ ] T-CLOSE-1 Botón `×` por pestaña en `SessionAreaView` (hover, callback
      `onCloseRequested: (String) -> Void` en `SessionTabHosting`). Depende de: nada.
      Test: UI test de `SessionAreaView` — `×` visible solo on hover, pulsarlo invoca el
      callback con el `identifier` correcto, no afecta a otras pestañas. Criterio: cero
      regresión en el empty-state ni en pestañas sin botón de cierre (si se decide
      excluir alguna, p. ej. ninguna por ahora: todas las pestañas de sesión lo llevan).
      → REQ-1
- [ ] T-CLOSE-2 Reasignación contextual de `⌘W`
      (`closeActiveSessionOrWindow(_:)`: pestaña de sesión activa → cierra pestaña;
      si no → `performClose` como hoy). Depende de: T-CLOSE-1 (necesita saber si la
      pestaña activa es una sesión SSH, vía `TerminalTabManager.openInstanceIDs`).
      Test: con una pestaña SSH seleccionada, `⌘W` cierra solo esa pestaña y la ventana
      permanece abierta; sin pestañas, `⌘W` cierra la ventana (comportamiento actual
      preservado). Criterio: ningún otro atajo del menú `File`/`Edit` cambia. → REQ-2
- [ ] T-CLOSE-3 `SessionCloseConfirmer` + diálogo de confirmación individual
      (`hasActiveTransfer`, `recentOutputWithinWindow`, `NSAlert` sheet/modal). Depende
      de: nada (paralelizable con T-CLOSE-1/2). Test: transferencia Files en curso →
      confirma siempre; sin transferencia y sin salida reciente → cierra sin preguntar;
      salida reciente dentro de la ventana configurada → confirma; heurística no
      evaluable → cierra sin preguntar (fail-safe). Criterio: nunca más de un diálogo
      por pestaña cerrada. → REQ-3,6
- [ ] T-CLOSE-4 Integración de cierre individual end-to-end
      (`×`/`⌘W` → `SessionCloseConfirmer` → `TerminalTabManager.close` →
      `onSessionEnded` → regla de sesión compartida con Files, ya existente). Depende
      de: T-CLOSE-1, T-CLOSE-2, T-CLOSE-3. Test de regresión: cerrar una pestaña SSH con
      una pestaña Files abierta sobre la misma instancia NO cierra la `SshSession`
      (sigue sirviendo a Files); cerrarla sin pestaña Files SÍ cierra la sesión y libera
      el stream de `TunnelKit`; cerrar dos veces (race) no duplica `onSessionEnded` ni
      lanza error. Criterio: ninguna sesión queda huérfana (socket), ninguna se cierra
      de más (mientras Files la usa). → REQ-4,6
- [ ] T-CLOSE-5 `windowShouldClose` + confirmación agregada + cierre de todas las
      pestañas (SSH vía `TerminalTabManager.closeAll()`, Files vía
      `SftpBrowsers.closeAll()`, ambas ya existentes). Depende de: T-CLOSE-3 (reutiliza
      el mismo `SessionCloseConfirmer`), T-CLOSE-4. Test: cerrar la ventana con 3
      pestañas SSH sin actividad → cierra sin diálogo; con 1 de 3 activa → un único
      diálogo agregado, confirmar cierra las 3; cancelar deja la ventana abierta y las 3
      pestañas intactas. Criterio: cero `NSAlert` duplicados (uno por cierre de ventana,
      no uno por pestaña). → REQ-5

Fuera de estas tasks (explícito, no bloquea): pestañas RDP (ciclo de vida propio, ver
`specs/rdp/tasks.md` T-RDP-6) y confirmación de cierre específica de la pestaña Files
cuando se cierra directamente por su propio `×` (ya conceptualmente cubierta por
`specs/sftp/`, esta spec solo exige que el cierre del **terminal** respete una
transferencia activa en Files, no al revés).

Secuencia: T-CLOSE-1 ∥ T-CLOSE-3 (independientes) → T-CLOSE-2 (necesita T-CLOSE-1) →
T-CLOSE-4 (necesita 1, 2 y 3) → T-CLOSE-5 (necesita 3 y 4).
