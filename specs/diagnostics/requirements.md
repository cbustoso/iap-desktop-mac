# Spec Diagnostics — requirements (EARS)

Ref: `docs/feature-parity.md` §12 (Diagnóstico) · Linear GH-54.
Origen C#: `Google.Solutions.IapDesktop.Core/ClientModel/Transport/*` (prueba de conectividad
implícita vía `ProbeAsync`), `Google.Solutions.IapDesktop.Application/Diagnostics/HelpTopics.cs`
y `Core/HelpTopics.cs` (`CreateIapFirewallRule`, `IapAccess`, `ProxyConfiguration`),
`Google.Solutions.IapDesktop.Extensions.Diagnostics/*` (panel interno de debug),
`Session/ToolWindows/Diagnostics/DiagnosticsCommands.cs` (genera HTML con enlaces
`iap-rdp://`). El original NO tiene un test de diagnóstico dedicado ni un chequeo
proactivo de firewall: esta spec se construye desde cero (paridad conceptual, no de código,
según §12 del documento de paridad: "Implementar desde cero en M4").

## REQ-DIAG-1 — Test de conectividad IAP end-to-end
- WHEN el usuario invoca "Probar conectividad" (por proyecto/zona/instancia o de forma
  general) THEN el sistema SHALL ejecutar una secuencia de chequeos independientes, en
  orden, deteniéndose en el primer fallo bloqueante pero reportando todos los pasos
  evaluados hasta ese punto: (1) permisos IAM (REQ-DIAG-2), (2) alcance de firewall
  (REQ-DIAG-3), (3) apertura de WebSocket contra el endpoint IAP (REQ-DIAG-4).
- El sistema SHALL producir un resultado estructurado (`DiagnosticsReport`) con un
  `DiagnosticStepResult` por paso (`.passed` / `.failed(reason:)` / `.skipped(because:)` /
  `.notApplicable`), nunca un booleano único, para que la UI muestre qué paso concreto
  falló (paridad con el espíritu de mensajes accionables de `HelpTopics`).
- Cada `DiagnosticStepResult` fallido SHALL incluir un `HelpTopic` o URL de ayuda cuando
  exista equivalente (paridad `CreateIapFirewallRule`, `IapAccess`, `ProxyConfiguration`).
- El test SHALL ser invocable tanto desde la UI (`ExplorerUI`, acción de instancia) como
  mediante un comando reutilizable por tests automatizados (sin acoplar la lógica a
  `AppKit`/`SwiftUI`).

## REQ-DIAG-2 — Verificación de permisos IAM
- WHEN se ejecuta el chequeo de permisos THEN el sistema SHALL invocar
  `testIamPermissions` sobre el recurso de instancia (paridad con el patrón ya existente
  en `GCPClient.canResetWindowsCredentials`, mismo endpoint
  `POST .../instances/{instance}/testIamPermissions`) solicitando como mínimo
  `iap.tunnelInstances.accessViaIAP` y `compute.instances.get`.
- IF el permiso `iap.tunnelInstances.accessViaIAP` falta THEN el sistema SHALL reportar
  el paso como `.failed` con mensaje accionable (rol IAM requerido:
  "IAP-Secured Tunnel User" / `roles/iap.tunnelResourceAccessor`) y SHALL NOT continuar
  asumiendo acceso (fail-closed; el original es fail-open vía `IsAccessGrantedAsync`,
  pero esta spec exige reportarlo explícitamente al usuario en vez de fallar en
  silencio más adelante).
- IF `compute.instances.get` falta THEN el sistema SHALL reportar el paso como `.failed`
  indicando que no puede ni siquiera leer el estado de la instancia, SHALL NOT ejecutar
  los pasos posteriores (firewall/WebSocket dependen de poder resolver la instancia).
- IF la llamada a `testIamPermissions` falla por error de red o HTTP≠200/403 THEN el
  sistema SHALL reportar el paso como `.failed` con el motivo HTTP (paridad
  `GoogleAPIFailure`), distinguiéndolo de un permiso efectivamente denegado (403 con
  lista de permisos vacía).

## REQ-DIAG-3 — Chequeo de regla de firewall para el rango IAP
- WHEN se ejecuta el chequeo de firewall THEN el sistema SHALL listar las reglas de
  firewall del proyecto/red relevante (`compute.firewalls.list`) y SHALL evaluar si
  existe al menos una regla `ALLOW` de ingreso que cubra el rango de origen
  `35.235.240.0/20` (rango fijo de IAP TCP forwarding, documentado en
  `docs/feature-parity.md` §12 — el original NO lo codifica, solo en documentación) para
  el puerto de destino relevante (22/TCP para SSH, 3389/TCP para RDP, o el puerto
  configurado del túnel).
- El sistema SHALL resolver la red (VPC) y las etiquetas/tags de destino de la regla
  contra la configuración de red de la instancia objetivo (`networkInterfaces`), de
  forma que una regla que no aplique a la instancia (red distinta, tag de destino que la
  instancia no tiene) SHALL NOT contar como cobertura válida.
- IF ninguna regla cubre `35.235.240.0/20` para el puerto relevante THEN el sistema
  SHALL reportar el paso como `.failed` con un mensaje accionable (paridad
  `HelpTopics.CreateIapFirewallRule`: enlace/instrucción para crear la regla) y SHALL
  incluir el comando `gcloud compute firewall-rules create` equivalente como texto de
  ayuda copiable.
- IF el usuario no tiene permiso `compute.firewalls.list` THEN el sistema SHALL reportar
  el paso como `.skipped(because:)` (no bloqueante, dado que es un chequeo informativo)
  en vez de `.failed`, indicando que no se pudo verificar.

## REQ-DIAG-4 — Probe de WebSocket contra el endpoint IAP
- WHEN se ejecuta el probe de transporte THEN el sistema SHALL intentar abrir (y cerrar
  inmediatamente tras éxito) una conexión WebSocket real contra el endpoint de IAP TCP
  forwarding (`IapEndpoint`/`WebSocketTransport` de `TunnelKit`) para el proyecto, zona,
  instancia, interfaz de red y puerto objetivo, sin reutilizar un túnel ya abierto por el
  usuario (conexión de diagnóstico aislada, descartable).
- El sistema SHALL aplicar un timeout configurable (paridad con `ProbeAsync` implícito
  del original) y SHALL distinguir en el resultado al menos estas causas de fallo:
  error de autenticación/token (401/403 del handshake), host/puerto no accesible
  (timeout de red, consistente con firewall bloqueando — REQ-DIAG-3), y error de
  protocolo IAP (`SshRelayCloseCode`/`TunnelError` de `TunnelKit`).
- IF el probe tiene éxito THEN el sistema SHALL cerrar la conexión sin dejar un túnel
  local abierto ni puertos reservados tras finalizar el diagnóstico.
- El resultado SHALL incluir latencia de conexión (tiempo hasta el primer byte/ack del
  servidor) cuando el probe tenga éxito, como dato informativo para soporte.

## REQ-DIAG-5 — Export de OSLog para soporte
- WHEN el usuario solicita "Exportar diagnóstico"/"Exportar logs" THEN el sistema SHALL
  recolectar las entradas de OSLog de los subsistemas relevantes de la app (AuthKit,
  SSHKit, RDPBridge, TunnelKit, GCPClient, SettingsStore) dentro de una ventana de tiempo
  configurable (p. ej. última hora / última sesión) usando `OSLogStore`.
- El export SHALL incluir el `DiagnosticsReport` de la última ejecución del test de
  conectividad (REQ-DIAG-1) si existe, más metadata de entorno no sensible: versión de
  la app, build (paridad `BuildInfo` de `AuthKit`), macOS version, arquitectura
  (arm64/x86_64).
- El sistema SHALL producir un único archivo exportable (texto plano o `.zip`) que el
  usuario pueda guardar o adjuntar manualmente a un ticket de soporte; el sistema SHALL
  NOT subir el archivo a ningún backend por su cuenta (sin telemetría automática de
  contenido de logs).
- El sistema SHALL redactar el export con las mismas reglas que `LogRedaction` de
  `AuthKit` (tokens, cookies, Authorization headers, llaves privadas, contraseñas)
  antes de escribir el archivo; el export SHALL NOT contener ningún secreto en claro
  (mismo criterio que REQ-SSH-7/REQ-RDP-8).

## REQ-DIAG-6 — Seguridad y observabilidad
- El sistema SHALL NOT registrar en OSLog durante la propia ejecución del diagnóstico
  ningún token de acceso, llave efímera, ni cuerpo completo de respuesta IAM/firewall
  (solo el resultado booleano/motivo tipado por paso).
- El sistema SHALL etiquetar en OSLog cada ejecución de diagnóstico con una categoría
  propia (`com.iapdesktop.mac.diagnostics`) distinta de la categoría de sesión normal,
  para facilitar su filtrado en el export (REQ-DIAG-5).

## Trazabilidad
REQ-DIAG-1 → T-DIAG-1,5 · REQ-DIAG-2 → T-DIAG-2 · REQ-DIAG-3 → T-DIAG-3 ·
REQ-DIAG-4 → T-DIAG-4 · REQ-DIAG-5 → T-DIAG-6 · REQ-DIAG-6 → T-DIAG-2,3,4,6.
