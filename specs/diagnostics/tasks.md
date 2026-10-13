# Spec Diagnostics — tasks (→ issues Linear)

- [ ] T-DIAG-1 `DiagnosticsTarget`/`DiagnosticStepResult`/`DiagnosticsReport` (tipos base,
      sin lógica de red). Depende de: nada. Test: construcción y `isFullyPassed` con
      combinaciones de pasos passed/failed/skipped. Criterio: ningún enum usa `default:`
      que oculte un caso no migrado (paridad `specs/ssh/`, `specs/rdp/`). → REQ-1
- [ ] T-DIAG-2 `GCPClient.testIapTunnelPermissions` (`iap.tunnelInstances.accessViaIAP` +
      `compute.instances.get`, extiende patrón de `canResetWindowsCredentials`).
      Depende de: T-DIAG-1. Test: mock `GCPStubURLProtocol` con 200/permisos completos,
      403/permiso parcial, 403/ninguno, HTTP 500. Criterio: fail-closed (permiso faltante
      → `.failed`, nunca `.passed` por omisión). → REQ-2,6
- [ ] T-DIAG-3 `GCPClient.firewallRulesCoveringIapRange` (list + filtro CIDR
      `35.235.240.0/20` incluido en `sourceRanges`, incl. `0.0.0.0/0`; filtro de red/tags
      contra la instancia objetivo). Depende de: T-DIAG-1. Test: regla exacta, regla
      `0.0.0.0/0`, regla de otra VPC (no cuenta), regla con tag que la instancia no tiene
      (no cuenta), 403 al listar → `.skipped`. Criterio: comparación de rangos CIDR
      correcta (no solo igualdad de string). → REQ-3,6
- [ ] T-DIAG-4 `TunnelKit.WebSocketProbe` (connect+handshake+primer mensaje+close sobre
      `IapEndpoint`, sin crear `RelaySession` completo; mide latencia; clasifica
      auth/network/protocol error). Depende de: T-DIAG-1. Test: `ScriptedChannel`/
      `ScriptedOpener` simulando éxito, 401 en upgrade, timeout de conexión,
      `SshRelayCloseCode` de error tras conectar. Criterio: no deja túnel ni puerto local
      abierto tras el probe (éxito o fallo). → REQ-4,6
- [ ] T-DIAG-5 `DiagnosticsRunner.run(target:)` (orquesta T-DIAG-2 → T-DIAG-3 → T-DIAG-4
      secuencialmente; corta tras IAM bloqueante, continúa si firewall solo informativo
      falla). Depende de: T-DIAG-2, T-DIAG-3, T-DIAG-4. Test: integración con los tres
      clientes mockeados cubriendo cada combinación de corte temprano vs continuación.
      Criterio: reporta todos los pasos evaluados hasta el punto de corte, nunca un
      booleano único. → REQ-1
- [ ] T-DIAG-6 `DiagnosticsExporter.export` (OSLogStore + `AuthKit.LogRedaction` +
      `DiagnosticsReport` + `BuildInfo`/entorno, a archivo local). Depende de: T-DIAG-5,
      `AuthKit.LogRedaction` (ya entregado). Test: assert de redacción (sin tokens/
      llaves/contraseñas en el archivo exportado, mismo criterio que T-AUTH-9/T-SET-10/
      T-RDP-9); assert de que no se realiza ninguna llamada de red durante el export.
      Criterio: cero secretos en el archivo generado (revisión + test). → REQ-5,6

Fuera de estas tasks (referencia, no bloquea): acción de UI "Diagnosticar conexión" en
`ExplorerUI` y botón "Exportar" que invocan `DiagnosticsRunner`/`DiagnosticsExporter`; se
especifica junto con la implementación de UI, análoga a `VmControlAction`.

Secuencia: T-DIAG-1 → (2 ∥ 3 ∥ 4) → 5 → 6. T-DIAG-2, T-DIAG-3 y T-DIAG-4 son
paralelizables entre sí (cada uno sobre un cliente distinto, `GCPClient`×2 + `TunnelKit`).
