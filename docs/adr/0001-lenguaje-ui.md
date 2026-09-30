# ADR-0001: Lenguaje y UI — Swift 6 + SwiftUI (AppKit donde haga falta)

- Estado: **Propuesto** (Fase 0, pendiente de aprobación)
- Fecha: 2026-09-30
- Contexto: paridad con IAP Desktop (C#/.NET + WinForms + DockPanelSuite + MVVM). Ver `docs/feature-parity.md`.

## Decisión

- **Swift 6** (strict concurrency, `async/await` + actors, cero data races), **macOS 14+**, **Universal Binary** (arm64 + x86_64).
- **SwiftUI** como UI por defecto; **AppKit** (`NSViewRepresentable`, `NSOutlineView` si hace falta, menús, `NSSplitView`) solo donde SwiftUI no llegue (terminal, outline denso, drag&drop avanzado).
- **Swift Package Manager** modular: `AuthKit`, `GCPClient`, `TunnelKit`, `SSHKit`, `TerminalUI` (SwiftTerm), `SFTPKit`, `RDPBridge`, `SettingsStore`, `App`.
- Persistencia: `UserDefaults (suite)` + **Keychain** para secretos/tokens (nunca disco plano ni logs); MDM Managed Preferences para políticas (equivale a GPO).
- Logs: **OSLog** estructurado con niveles + exportación.

## Alternativas consideradas

1. **AppKit 100%**: máximo control (paridad con WinForms/DockPanel), pero coste alto y sin beneficio para MVP; se descarta como base, se reserva para piezas puntuales.
2. **Electron/Tauri**: reutilizaría lógica, pero rompe requisito "app nativa", firma/notarización más frágil y peor integración Keychain/terminal. Descartado.
3. **Port .NET MAUI / Avalonia**: no nativo macOS, ecosistema RDP/SSH débil, firma compleja. Descartado.

## Consecuencias

- Reimplementar MVVM/DockPanel con `@Observable` + `NavigationSplitView`/pestañas; `Registry/GPO/DPAPI/CNG` → UserDefaults/MDM/Keychain/Security.framework (ver §13 de la matriz).
- `TerminalUI` depende de SwiftTerm; `SSHKit` decide transporte (ver ADR-0002 para túnel).
- CI debe validar `BUILD_LIBRARY_FOR_DISTRIBUTION`, `SWIFT_STRICT_CONCURRENCY=complete`, sin warnings.

## Puerta de aprobación

- [ ] Confirmar macOS 14+ como mínimo y Universal Binary obligatorio.
