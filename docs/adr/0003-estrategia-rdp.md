# ADR-0003: Estrategia RDP — FreeRDP embebido (principal) + lanzar "Windows App" con .rdp (fallback)

- Estado: **Propuesto** (Fase 0, pendiente de aprobación)
- Fecha: 2026-09-30
- Contexto: original usa MSTSC ActiveX (`AxMSTSCLib`/`MSTSCLib`, `Terminal/Controls/RdpClient.cs`, `Session/Protocol/Rdp/*`, `Session/ToolWindows/Session/RdpView.cs`). En macOS no existe MSTSC. Ver `docs/feature-parity.md` §6.

## Decisión

1. **Vía principal: FreeRDP embebido** (`RDPBridge` sobre FreeRDP 3.x vía SPM-C / XCFramework, `NSView` bridged a SwiftUI):
   - Paridad: sesiones múltiples con pestañas/fullscreen, NLA/CredSSP, `RestrictedAdmin`/`/admin`, `ColorDepth 16/24/32`, redirecciones (clipboard, drive, printer, smartcard, audio in/out, device/port), DPI scaling, auto-resize, `KeyboardHookMode`, hotkeys, `ConnectionBar`, error 516 → mensaje RDSH (forzar admin).
   - Túnel: FreeRDP apunta a `127.0.0.1:puertoLocal` del `TunnelKit` (igual que hoy apunta al `IapListener`).
   - Coste: interop C, firma/notarización del binario nativo, mantenimiento de versión. Riesgo A pero es la única vía con paridad real.
2. **Fallback: generar `.rdp` y lanzar el cliente de Microsoft ("Windows App")**:
   - `RDPBridge` genera `.rdp` (server `127.0.0.1:port`, credenciales vía Keychain/prompt, flags de redirección soportadas) y lo abre con `NSWorkspace`.
   - Cubre M2 temprano y entornos donde FreeRDP falle; sin pestañas integradas ni control fino (redirecciones limitadas a lo que el cliente externo soporte).
   - Requiere que el usuario tenga instalado "Windows App" (antes "Microsoft Remote Desktop").
3. **Secuencia**: M2 implementa primero el fallback `.rdp` (desbloquea credenciales Windows + VM ops end-to-end), luego FreeRDP embebido detrás de feature-flag; la spec fija los enums numéricos congelados (`RdpParameters`) para que ambas vías compartan settings.

## Alternativas consideradas

1. **Solo cliente externo**: mínimo esfuerzo, pero sin pestañas/fullscreen integrados, sin `ConnectionBar`, sin control de redirecciones/WebAuthn/DPI — no es paridad. Descartado como única vía.
2. **Implementar RDP desde cero en Swift**: inviable (NLA/CredSSP/RDP graphics stack). Descartado.
3. **Royal TSX / otro SDK comercial**: licencias y firma problemáticas. Descartado.

## Consecuencias

- `RDPBridge` define `RdpParameters` congelados (puertos, timeouts 30s, auth levels) compartidos por ambas vías.
- Empaquetado (M4) debe incluir el XCFramework FreeRDP en el Universal Binary + entitlements de red/Keychain.
- Credenciales Windows (reset GCE) son independientes del renderer y van primero en M2.

## Puerta de aprobación

- [ ] Confirmar FreeRDP como vía principal + fallback `.rdp` (orden M2: fallback primero, embebido detrás de flag).
