# Spec Diagnostics — design (nuevo módulo, trabajo en `App`/`GCPClient`/`TunnelKit`)

Ref: requirements.md · Origen C#: `IapDesktop.Core/ClientModel/Transport/*`,
`IapDesktop.Application/Diagnostics/HelpTopics.cs`, `Core/HelpTopics.cs`,
`IapDesktop.Extensions.Diagnostics/*`, `Session/ToolWindows/Diagnostics/DiagnosticsCommands.cs`.
Sin librería dedicada en el original (`Extensions.Diagnostics` es un panel de debug
interno); esta spec diseña el flujo desde cero, reutilizando los clientes ya existentes
(`GCPClient`, `TunnelKit`) en vez de crear un módulo `DiagnosticsKit` separado — ver
decisión de ubicación más abajo.

## Ubicación del código

- No se crea un nuevo target SPM. Los chequeos viven como:
  - `GCPClient`: nuevos métodos `testIapTunnelPermissions`, `firewallRulesCoveringIapRange`
    (extienden el patrón ya usado por `canResetWindowsCredentials` /
    `testIamPermissions` en `WindowsCredentials.swift`).
  - `TunnelKit`: un `WebSocketProbe` ligero que reutiliza `WebSocketTransport`/
    `IapEndpoint` para abrir y cerrar una conexión de diagnóstico, sin pasar por
    `RelaySession` completo (no necesita multiplexar datos, solo confirmar handshake).
  - Un nuevo tipo `DiagnosticsRunner` (candidato: `Sources/App/Diagnostics.swift`, junto a
    `SshCredentialServices.swift`/`RdpConnect.swift`, mismo patrón de "servicio de
    aplicación" que ya usa `App` para componer `GCPClient` + `AuthKit`) orquesta los
    tres pasos y produce el `DiagnosticsReport`.
  - Export de OSLog (REQ-DIAG-5): `AuthKit.LogRedaction` se reutiliza tal cual (ya es
    público); el export en sí vive en el mismo `DiagnosticsRunner` o un
    `DiagnosticsExporter` adyacente.
- Motivo: los tres chequeos son llamadas puntuales sobre clientes que ya existen
  (`GCPClient` para IAM/firewall, `TunnelKit` para el probe); no hay suficiente lógica de
  dominio propia para justificar un target nuevo (a diferencia de `SSHKit`/`RDPBridge`,
  que sí encapsulan un protocolo completo).

## Flujo (`DiagnosticsRunner.run(target:) -> DiagnosticsReport`)

```
DiagnosticsRunner.run(target: DiagnosticsTarget(project, zone, instance, port, protocol))
  1. GCPClient.testIapTunnelPermissions(project, zone, instance)
       → DiagnosticStepResult (.passed | .failed(reason: .missingPermission(name:)) | .failed(reason: .httpError))
       SI falla con permiso faltante bloqueante (iap.tunnelInstances.accessViaIAP o
       compute.instances.get) → cortar aquí, reportar solo este paso.
  2. GCPClient.firewallRulesCoveringIapRange(project, network, targetTags, port)
       → DiagnosticStepResult (.passed | .failed(reason: .noMatchingRule) | .skipped(because: .listPermissionDenied))
       (no bloqueante: se continúa al paso 3 aunque falle, es informativo)
  3. TunnelKit.WebSocketProbe.probe(endpoint: IapEndpoint, timeout:)
       → DiagnosticStepResult (.passed(latency:) | .failed(reason: .authRejected | .networkUnreachable | .protocolError(TunnelError)))
  → DiagnosticsReport(steps: [1, 2, 3], startedAt, finishedAt)
```

- Cada paso es independiente y testeable por separado (inyección de `GCPClient`/
  `TunnelKit` mockeados, mismo patrón que `Tests/GCPClientTests/GCPStubURLProtocol` y
  `Tests/TunnelKitTests/ScriptedChannel`).
- El `DiagnosticsRunner` SHALL ejecutar los pasos secuencialmente (el paso 3 depende de
  saber que la instancia es alcanzable; no hay paralelismo necesario ni beneficioso aquí).

## Tipos

```swift
struct DiagnosticsTarget {
    let project, zone, instance: String
    let port: UInt16          // 22 (SSH) o 3389 (RDP) u otro configurado
    let protocolKind: DiagnosticsProtocol  // .ssh | .rdp | .custom
}

enum DiagnosticStepResult {
    case passed(info: String? = nil)
    case failed(reason: DiagnosticFailureReason, helpTopic: HelpTopic?)
    case skipped(because: String)
    case notApplicable
}

enum DiagnosticFailureReason {
    case missingPermission(String)
    case httpError(status: Int, message: String)
    case noMatchingFirewallRule(expectedRange: String, port: UInt16)
    case firewallListDenied
    case authRejected
    case networkUnreachable
    case protocolError(TunnelError)
}

struct DiagnosticsStep {
    let name: String                 // "iam", "firewall", "websocket"
    let result: DiagnosticStepResult
}

struct DiagnosticsReport {
    let target: DiagnosticsTarget
    let steps: [DiagnosticsStep]
    let startedAt: Date
    let finishedAt: Date
    var isFullyPassed: Bool { steps.allSatisfy { if case .passed = $0.result { true } else { false } } }
}
```

## Chequeo IAM (`GCPClient.testIapTunnelPermissions`)

- Extiende el patrón de `canResetWindowsCredentials` (`WindowsCredentials.swift:76-89`):
  mismo endpoint `POST .../instances/{instance}/testIamPermissions`, pero con la lista
  `["iap.tunnelInstances.accessViaIAP", "compute.instances.get"]`.
- Devuelve `[String: Bool]` (permiso → concedido) en vez de un único `Bool`, para que
  `DiagnosticsRunner` distinga cuál de los dos falta y componga el mensaje correcto.
- `403` sin permisos en la respuesta → ambos permisos `false` (fail-closed, no se asume
  nada); error HTTP distinto de 200/403 → se propaga como `.httpError`.

## Chequeo de firewall (`GCPClient.firewallRulesCoveringIapRange`)

- Llama `compute.googleapis.com/compute/v1/projects/{project}/global/firewalls` (list),
  filtra reglas `direction=INGRESS`, `allowed[].IPProtocol=tcp`, `sourceRanges` que
  contenga o incluya `35.235.240.0/20` (comparación de rangos CIDR, no solo igualdad de
  string — una regla `0.0.0.0/0` también cubre el rango IAP y SHALL contar como válida).
- Resuelve la red de la instancia objetivo vía `GCPClient.getInstance` (ya existente,
  `ComputeInstance.networkInterfaces`) para descartar reglas de otra VPC.
- Compara `targetTags`/`targetServiceAccounts` de la regla contra las tags de la
  instancia; una regla sin `targetTags` aplica a toda la red (igual que GCE).
- `403` al listar → `.skipped(because: .firewallListDenied)` (no bloqueante, REQ-DIAG-3).

## Probe de WebSocket (`TunnelKit.WebSocketProbe`)

- Reutiliza `IapEndpoint` (construcción de URL `wss://tunnel.cloudproxy.app/v4/connect?...`,
  ya existente) y el mismo cliente WebSocket que `WebSocketTransport`, pero SOLO hace
  connect + handshake + lee el primer mensaje (`ConnectSuccessSid` esperado) + cierra,
  sin crear un `RelaySession` completo ni reservar puerto local.
- Mide `latency` como el tiempo entre el `connect()` y la recepción del primer mensaje
  válido del servidor.
- Clasifica errores: código HTTP 401/403 en el upgrade → `.authRejected`; timeout de
  conexión TCP/TLS → `.networkUnreachable`; mensaje de error IAP tras conectar
  (`SshRelayCloseCode`) → `.protocolError`.

## Export de OSLog (`DiagnosticsExporter`)

```
DiagnosticsExporter.export(lastReport: DiagnosticsReport?, window: TimeInterval) -> URL
  1. OSLogStore.local() → entries(matching: predicate de subsystem/categoría, within: window)
  2. Para cada entrada: AuthKit.LogRedaction.redact(line) antes de escribir.
  3. Serializa: header (BuildInfo, macOS version, arch) + DiagnosticsReport (si existe,
     en texto legible, sin volcar bodies HTTP crudos) + líneas de log redactadas.
  4. Escribe a un archivo temporal (`.txt` o `.zip` si >1 subsistema con mucho volumen)
     y devuelve la URL para que la UI ofrezca "Guardar como…"/"Compartir".
- SHALL NOT invocar ningún endpoint de red: la exportación es puramente local a disco.
```

## Errores tipados
`DiagnosticsError.{targetUnresolved, probeTimedOut, exportWriteFailed}` para fallos de
infraestructura del propio diagnóstico (distintos de `DiagnosticFailureReason`, que son
resultados de negocio esperables y SHALL NOT lanzarse como `throw`).

## Integración UI (fuera de alcance de esta spec, referencia)
`ExplorerUI` expondrá una acción "Diagnosticar conexión" por instancia (análoga a
`VmControlAction`) que invoca `DiagnosticsRunner.run` y muestra el `DiagnosticsReport`
paso a paso; el botón "Exportar" dispara `DiagnosticsExporter.export`. El diseño
detallado de esa UI se especifica junto con la implementación (no bloquea T-DIAG-1..6).
