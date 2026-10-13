# Spec Inventory — requirements (EARS, breve)

Ref: `docs/feature-parity.md` §11 (Inventario = **Guest Attributes**, NO `osconfig.googleapis.com`)
· Linear GH-?? (pendiente de crear).
Origen C#: `Session/Protocol/App/GuestOs/Inventory/*`, `Session/ToolWindows/PackageInventory/*`
(`GetGuestAttributesAsync(path=GuestOsInfo.GuestAttributePath)`; zona/proyecto = `ListInstances`
+ fan-out por instancia; filtra Windows para listados de zona/proyecto). No se encontró
checkout local de `/tmp/iap-desktop-ref`; el formato de guest attributes de abajo está
verificado contra la documentación pública de GCE (`instances.getGuestAttributes`,
`compute/docs/metadata/manage-guest-attributes`) y el agente `GoogleCloudPlatform/osconfig`
(`packages/packages.go`), no contra el código fuente de iap-desktop.

## REQ-INV-1 — Fuente de datos: Guest Attributes, no osconfig
- El sistema SHALL obtener el inventario de paquetes vía
  `instances.getGuestAttributes` (`queryPath=guestInventory/`), NUNCA vía
  `osconfig.googleapis.com` (paridad explícita con el original, §11: "NO usa
  osconfig.googleapis.com").
- El sistema SHALL requerir que el guest agent (`google-guest-agent`) esté habilitado en
  la instancia y que `enable-guest-attributes` esté activo en metadata; si la clave
  `guestInventory/InstalledPackages` no está presente en la respuesta, el sistema SHALL
  tratarlo como "inventario no disponible" (no error fatal), no como fallo de red.

## REQ-INV-2 — Parseo del payload `InstalledPackages`
- El valor `InstalledPackages` (y `PackageUpdates`, mismo formato) SHALL llegar como
  texto **base64 de un `gzip`** de un documento JSON con una clave por gestor de
  paquetes (`apt`, `deb`, `yum`, `rpm`, `zypper`, `zypperPatches`, `cos`, `snap`, `gem`,
  `pip`, `googet` en Linux/COS/Windows-googet; `wua`, `qfe` en Windows) cuyo valor es un
  array de objetos de paquete.
- El sistema SHALL decodificar base64 → `gunzip` → JSON y aplanar el resultado a una
  lista única `[InventoryPackage]` (nombre, versión, arquitectura si aplica, gestor de
  origen), preservando el gestor de origen para que la UI pueda filtrar/agrupar.
- IF el base64 es inválido, el contenido no es un stream `gzip` válido, o el JSON
  resultante no decodifica THEN el sistema SHALL fallar con un error tipado específico
  por etapa (`notBase64` / `notGzip` / `truncatedHeader` / `decompressionFailed` /
  `invalidJSON`), nunca un error genérico, para poder diagnosticar guest agents viejos
  o payloads corruptos.
- Un gestor desconocido (clave no listada arriba) SHALL ignorarse sin fallar (paridad
  con la tolerancia del original a nuevos gestores de paquetes futuros); una entrada sin
  `name`/`Title`/`Caption` SHALL ignorarse sin fallar.

## REQ-INV-3 — Fan-out por zona/proyecto
- WHEN el usuario pide inventario a nivel zona/proyecto (no de una sola instancia) THEN
  el sistema SHALL listar las instancias (`ListInstances`, ya existente en `GCPClient`)
  y hacer fan-out de `getGuestAttributes` por cada una, con paralelismo limitado
  (throttle configurable, paridad §11: "throttle + paralelismo limitado").
- El sistema SHALL filtrar instancias Windows de los listados agregados de zona/proyecto
  (paridad §11: "filtra Windows para zona/proyecto"); a nivel de una sola instancia
  Windows SHALL mostrar su inventario normalmente (el filtro es solo para listados
  agregados, no para el panel de una instancia concreta).
- Un fallo de `getGuestAttributes` en una instancia individual (sin guest agent, sin
  permiso, instancia detenida) SHALL NOT abortar el fan-out completo: esa instancia se
  reporta como "sin datos" y el resto del listado continúa.

## REQ-INV-4 — Seguridad y observabilidad
- El sistema SHALL NOT registrar en OSLog el contenido decodificado del inventario
  (nombres de paquete pueden ser sensibles en contextos regulados); solo contadores
  (número de paquetes, gestor, duración de la llamada).

## Trazabilidad
REQ-INV-1 → T-INV-1 · REQ-INV-2 → T-INV-2 (cubierta por
`Tests/GCPClientTests/InventoryParsingTests.swift`, prototipo a mover a su módulo) ·
REQ-INV-3 → T-INV-3 · REQ-INV-4 → T-INV-2,3.
