# Spec SSH Close — requirements (EARS)

Ref: `docs/feature-parity.md` §4 (SSH), `specs/ssh/requirements.md` REQ-SSH-4/5
(terminal VT y reconexión) · Linear GH-63 (pedida por el dueño).
Alcance: cierre de pestañas de sesión **SSH** en `ExplorerUI.SessionAreaView` /
`TerminalUI.TerminalTabManager`. NO cubre pestañas RDP (fuera de alcance, ver
`specs/rdp/requirements.md` REQ-RDP-5 para su propio ciclo de vida de pestaña) ni la
pestaña "Files" (SFTP, `specs/sftp/`) salvo donde comparte la `SshSession` subyacente
con una pestaña de terminal (REQ-CLOSE-4).
Código de referencia leído (sin modificar): `Sources/TerminalUI/TerminalTabManager.swift`,
`Sources/TerminalUI/TerminalSessionView.swift`, `Sources/ExplorerUI/SessionAreaView.swift`,
`Sources/ExplorerUI/SessionTabHosting.swift`, `Sources/App/App.swift` (menú y
`wireSshConnect`), `Sources/App/SftpBrowse.swift` (compartición de sesión con Files).

## Estado actual (constatado en el código, no se repite como requisito)
- `TerminalTabManager.close(instanceID:)` y `.closeAll()` ya existen y hacen cierre
  limpio (cierra el canal/backend, quita la pestaña, notifica `onSessionEnded`); lo que
  falta es la **superficie de UI** que los invoque por pestaña (botón `×`, atajo) y la
  **confirmación** antes de invocarlos.
- `SessionAreaView` (`NSTabView`) hoy no dibuja un botón de cierre por pestaña.
- El atajo `⌘W` está asignado globalmente a `File → Close Window`
  (`NSWindow.performClose(_:)`, `Sources/App/App.swift:333`), que cierra toda la
  ventana — no una pestaña. Esta spec reasigna su significado cuando hay una pestaña de
  sesión activa (REQ-CLOSE-2).
- `wireSshConnect` ya desconecta la `SshSession` cuando `onSessionEnded` dispara, salvo
  que una pestaña Files siga usándola (`sftpBrowsers?.isUsing(session)`); el cierre
  manual por `×`/`⌘W` SHALL seguir exactamente esa misma regla (REQ-CLOSE-4).

## REQ-CLOSE-1 — Cierre individual por botón `×` en la pestaña
- Cada pestaña de sesión SSH en `SessionAreaView` SHALL mostrar un control de cierre
  (`×`) visible al pasar el ratón sobre la pestaña (paridad con el patrón estándar de
  pestañas de macOS: Safari, Terminal.app — visible on hover, no permanente para no
  recargar visualmente la barra de pestañas).
- WHEN el usuario pulsa el `×` de una pestaña THEN el sistema SHALL evaluar la
  confirmación (REQ-CLOSE-3) y, si procede, cerrar **solo esa pestaña** (REQ-CLOSE-4),
  SHALL NOT afectar a otras pestañas abiertas (RDP, Files, otras instancias SSH).
- El control de cierre SHALL ser alcanzable también sin ratón: clic central/medio sobre
  la pestaña (convención de pestañas de navegador) es opcional; el atajo de teclado
  (REQ-CLOSE-2) es la vía accesible obligatoria.

## REQ-CLOSE-2 — Atajo de teclado `⌘W` (cierre de la pestaña activa, no de la ventana)
- WHEN el foco está en una pestaña de sesión SSH (la pestaña seleccionada en
  `SessionAreaView` tiene una sesión SSH activa) y el usuario pulsa `⌘W` THEN el sistema
  SHALL cerrar esa pestaña (misma ruta que REQ-CLOSE-1: confirmación + limpieza),
  SHALL NOT cerrar la ventana completa del Explorer.
- WHEN no hay ninguna pestaña de sesión abierta (empty state de `SessionAreaView`, o el
  foco está en el árbol/panel de propiedades, no en el área de sesiones) THEN `⌘W`
  SHALL conservar su comportamiento actual (`File → Close Window`, cierra la ventana).
- La re-asignación de `⌘W` SHALL implementarse sin breaking change visible para el
  usuario en el resto de atajos del menú `File` (p. ej. `⌘N` para "Add project…" no
  cambia); el ítem de menú `File → Close Window` SHALL seguir existiendo para cerrar la
  ventana explícitamente desde el menú cuando sí hay pestañas abiertas (ver REQ-CLOSE-5
  para su propia confirmación en ese caso).

## REQ-CLOSE-3 — Confirmación si hay proceso activo en la sesión
- WHEN el usuario inicia el cierre de una pestaña (REQ-CLOSE-1/2) Y la sesión SSH de esa
  pestaña tiene un **proceso activo** (ver heurística abajo) THEN el sistema SHALL
  mostrar un diálogo de confirmación (`NSAlert`, mismo patrón que
  `ExplorerWindowController.confirm(_:for:)`: `messageText` = "¿Cerrar
  <título-pestaña>?", `informativeText` indicando que hay actividad en curso, botones
  "Close"/"Cancel") antes de proceder; SHALL NOT cerrar la pestaña si el usuario pulsa
  "Cancel".
- IF la sesión está en reposo (sin proceso activo detectado, p. ej. solo un prompt de
  shell esperando entrada) THEN el sistema SHALL cerrar la pestaña inmediatamente, SIN
  diálogo (paridad con Terminal.app: solo pregunta si "algo" sigue corriendo).
- **Heurística de "proceso activo"** (SSH remoto no expone process table local; se usa
  una señal observable desde el cliente, documentada como limitación conocida, no como
  detección exacta):
  1. Hay una transferencia SFTP en curso (`FileBrowserViewModel.transfers` con estado
     `.transferring`) sobre la misma `SshSession` compartida (pestaña Files abierta y
     activa) → se considera "proceso activo" sin ambigüedad.
  2. En su defecto, el sistema SHALL considerar la sesión "activa" si ha recibido salida
     del canal remoto (`TerminalBackend.output`) en una ventana reciente configurable
     (p. ej. últimos 2 segundos) sin que medie una pulsación de Enter con línea vacía
     del usuario inmediatamente antes (heurística de "comando en curso" vs "el usuario
     acaba de teclear algo"); esta señal SHALL documentarse como aproximada en el código
     (comentario, no en logs) y SHALL preferir el falso positivo (preguntar de más) al
     falso negativo (cerrar sin avisar mientras algo corre).
  3. Si no se puede evaluar la heurística (p. ej. el backend no expone timestamps de
     salida) THEN el sistema SHALL optar por NO preguntar (fail-safe hacia la acción
     explícita del usuario, consistente con que cerrar una pestaña de terminal inactiva
     es la operación común y no debe interrumpirse con diálogos innecesarios).
- La pestaña "Files" (SFTP) SHALL tener su propia confirmación si hay transferencias en
  curso en el momento de cerrarla directamente (fuera de alcance detallar aquí: ya
  cubierto conceptualmente por `specs/sftp/`); esta spec solo exige que cerrar la
  pestaña de **terminal** compruebe transferencias activas en una pestaña Files que
  comparta la misma sesión (regla 1 arriba).

## REQ-CLOSE-4 — Limpieza de sesión SSH + túnel al cerrar
- WHEN una pestaña de sesión SSH se cierra (confirmada o sin necesidad de confirmación)
  THEN el sistema SHALL:
  1. Dejar de enviar/recibir en el canal (`TerminalSessionView.close()`: `outbound.finish()`,
     `backend.close()`, cancelar el `feeder`).
  2. Quitar la pestaña de `SessionAreaView` (`host.closeSession(identifier:)`).
  3. Cerrar la `SshSession` subyacente (`SshSession.close()`) **solo si ninguna otra
     pestaña la sigue usando**: el sistema SHALL comprobar si hay una pestaña Files
     abierta compartiendo la misma sesión (paridad exacta con la regla ya existente en
     `wireSshConnect`/`SftpBrowsers.isUsing`) antes de cerrarla; si está compartida, el
     sistema SHALL cerrar solo el canal shell y dejar la `SshSession`/túnel vivos para
     la pestaña Files.
  4. Cuando la `SshSession` se cierra, el túnel IAP subyacente (`TunnelKit`/`RelayStream`
     que la transporta) SHALL cerrarse también si no hay ningún otro consumidor
     (paridad `specs/ssh/design.md` "Reconexión vía capa IAP": SSH no gestiona su propio
     transporte, pero al cerrar la última sesión que lo usa, el stream subyacente SHALL
     liberarse, no quedar huérfano).
- El cierre SHALL ser idempotente: cerrar una pestaña ya cerrada o cerrar dos veces la
  misma sesión (p. ej. race entre `×` y el canal terminando por su cuenta) SHALL NOT
  lanzar error ni duplicar notificaciones (`onSessionEnded` SHALL dispararse como máximo
  una vez por sesión, mismo criterio que el `guard` ya presente en
  `TerminalTabManager.close`).
- Un error al cerrar el canal remoto (p. ej. el socket ya estaba caído) SHALL NOT
  impedir completar los pasos 2–4 (la pestaña SHALL desaparecer de la UI igualmente;
  limpieza best-effort, nunca bloqueante).

## REQ-CLOSE-5 — Cerrar la ventana cierra todo
- WHEN el usuario cierra la ventana del Explorer (botón rojo, `File → Close Window`, o
  `⌘Q`/salir de la app) Y hay una o más pestañas de sesión SSH abiertas THEN el sistema
  SHALL evaluar la confirmación agregada: SHALL mostrar como máximo un diálogo de
  confirmación (no uno por pestaña) si **alguna** pestaña tiene proceso activo (misma
  heurística de REQ-CLOSE-3), listando o resumiendo cuántas sesiones se cerrarán.
- WHEN el usuario confirma (o no había ninguna sesión con proceso activo) THEN el
  sistema SHALL cerrar **todas** las pestañas de sesión SSH abiertas (equivalente a
  invocar REQ-CLOSE-4 para cada una) antes de permitir que la ventana termine de
  cerrarse (`windowShouldClose` SHALL devolver `false` hasta que la limpieza async
  termine, o SHALL completarla de forma sincronizada con el cierre — decisión de diseño
  en `design.md`).
- Cerrar la ventana SHALL limpiar igualmente las pestañas Files (SFTP) abiertas,
  reutilizando `SftpBrowsers.closeAll()` ya existente, para que ninguna `SshSession`
  quede huérfana tras cerrar la ventana.
- `applicationShouldTerminateAfterLastWindowClosed` ya devuelve `true`
  (`Sources/App/App.swift:300`): cerrar la única ventana del Explorer termina la app:
  esta spec SHALL NOT cambiar ese comportamiento, solo asegurar que la limpieza de
  sesiones ocurre antes de que el proceso termine (ya existe una red de seguridad
  parcial: `applicationWillTerminate` borra los `.rdp` generados, pero no cierra
  túneles SSH explícitamente — con el proceso terminando, los sockets se liberan por el
  SO, pero el cierre SHALL intentarse igual para notificar al servidor remoto y evitar
  sesiones zombie en el host, paridad con el espíritu de limpieza ya aplicado a RDP).

## REQ-CLOSE-6 — Seguridad y observabilidad
- El sistema SHALL NOT registrar en OSLog el contenido de la sesión ni el motivo
  detallado de la heurística de "proceso activo" más allá de un evento
  `session-close requested/confirmed/cancelled` con el identificador de instancia
  (sin datos de la sesión), paridad con REQ-SSH-7 (`specs/ssh/requirements.md`).

## Trazabilidad
REQ-CLOSE-1 → T-CLOSE-1 · REQ-CLOSE-2 → T-CLOSE-2 · REQ-CLOSE-3 → T-CLOSE-3 ·
REQ-CLOSE-4 → T-CLOSE-4 (ya parcialmente cubierto por código existente, test de
regresión) · REQ-CLOSE-5 → T-CLOSE-5 · REQ-CLOSE-6 → T-CLOSE-3,4.
