# IAP Desktop Mac

App nativa macOS con paridad funcional con [IAP Desktop](https://github.com/GoogleCloudPlatform/iap-desktop) (Windows).
Estado: **M0 (Fundación)** — specs Auth/Explorer/Tunnel + esqueleto SPM + CI. Ver `docs/feature-parity.md` y `docs/adr/`.

## Módulos (SPM)

`AuthKit` · `GCPClient` (REST Compute/IAP/OS Login/Logging) · `TunnelKit` · `SSHKit` · `TerminalUI` (SwiftTerm) · `SFTPKit` · `RDPBridge` · `SettingsStore` · `App`.

## Requisitos

- macOS 14+, Xcode 16+, Swift 6 (strict concurrency).
- `swift build`, `swift test`.
- Guía completa (CLT vs Xcode, workaround de tests, `.app`, snapshots,
  troubleshooting): [`docs/usage.md`](docs/usage.md).

## Metodología

Spec-driven + Linear: cada épica en `specs/<epic>/{requirements,design,tasks}.md`; cada tarea → issue Linear (proyecto "IAP Desktop Mac").
Ramas `feat/<LINEAR-ID>-slug`, commits `IAPM-123: …` (cuando el proyecto Linear tenga clave propia; hoy equipo `CBU`).
