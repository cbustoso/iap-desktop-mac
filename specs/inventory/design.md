# Spec Inventory — design (breve)

Ref: requirements.md · Origen C#: `Session/Protocol/App/GuestOs/Inventory/*`,
`Session/ToolWindows/PackageInventory/*`.

## Ubicación del código (futura)

- No existe módulo propio aún. El parser prototipo vive hoy en
  `Tests/GCPClientTests/InventoryParsingTests.swift` (tipos + tests en el mismo archivo,
  sin tocar `Sources/` — alcance de esta tarea es solo spec + tests). Cuando se implemente
  T-INV-1..3, estos tipos SHALL moverse a un target nuevo (candidato: `Sources/InventoryKit`,
  mismo patrón que `SFTPKit`: módulo pequeño, dependiente de `GCPClient` para el fan-out
  de `ListInstances`/`getGuestAttributes`) o, si el equipo decide que no amerita target
  propio, a `Sources/GCPClient/Inventory.swift` junto al resto de wrappers de Compute API
  (mismo criterio que `SerialPort.swift`/`WindowsCredentials.swift`).
- La llamada de red (`GCPClient.getGuestAttributes(project:zone:instance:queryPath:)`) y
  el fan-out (`InventoryCollector`, con `TaskGroup` + semáforo de concurrencia) NO están
  implementados todavía; esta spec solo fija el contrato de parseo, que es la parte con
  mayor riesgo de formato (base64+gzip+JSON heterogéneo por gestor).

## Flujo

```
GCPClient.getGuestAttributes(project, zone, instance, queryPath: "guestInventory/")
  → GuestAttributesResponse { variableKey, variableValue, queryValue.items[] }
  → extraer item con key == "InstalledPackages" (namespace "guestInventory")
  → GuestAttributeDecoder.decodeInstalledPackagesPayload(base64) -- base64 → gunzip → Data
  → PackageInventoryParser.parse(json: Data) -> [InventoryPackage]
```

- `GuestAttributesResponse` modela ambas formas que devuelve la API: variable única
  (`variableKey`/`variableValue`, cuando se pide `queryPath=guestInventory/InstalledPackages`
  exacto) y árbol (`queryValue.items[]`, cuando se pide el prefijo `guestInventory/`).
- `GuestAttributeDecoder.gunzip` implementa el parseo manual de la cabecera `gzip`
  (RFC 1952: magic `1f 8b 08`, flags `FTEXT/FHCRC/FEXTRA/FNAME/FCOMMENT`, tamaño
  descomprimido en los últimos 4 bytes del trailer) y delega la descompresión del
  stream `deflate` crudo en `Compression.framework`
  (`compression_decode_buffer(..., COMPRESSION_ZLIB)`, que en la API de Apple implementa
  deflate crudo, no el contenedor zlib — de ahí que haya que quitar a mano las cabeceras
  gzip/zlib antes de llamarlo). Sin dependencias SPM nuevas: `Compression` es framework
  de sistema en macOS.
- `PackageInventoryParser.parse` usa `JSONSerialization` (no `Decodable` estricto) porque
  el esquema por gestor es heterogéneo (Linux/COS/snap/gem/pip/googet usan
  `name`/`version`/`arch`; Windows `wua`/`qfe` usan `Title`/`UpdateID` o
  `Caption`/`HotFixID` sin `version`); normaliza con *best effort* por gestor conocido y
  descarta entradas sin nombre reconocible, en vez de fallar el documento completo por
  un gestor con esquema inesperado.

## Tipos (prototipo, hoy en el test file)

```swift
struct InventoryPackage: Equatable, Sendable {
    let manager: String       // "apt", "yum", "googet", "wua", …
    let name: String
    let version: String?
    let architecture: String?
}

enum GuestAttributeDecodingError: Error, Equatable {
    case notBase64, notGzip, truncatedHeader, decompressionFailed
}

enum InventoryParsingError: Error, Equatable {
    case missingInstalledPackagesKey, invalidJSON
}
```

## Fuera de alcance de esta tarea
Llamada HTTP real (`GCPClient.getGuestAttributes`), fan-out por zona/proyecto con
throttle (REQ-INV-3), filtro de instancias Windows en listados agregados, e integración
con un panel de UI (`ExplorerUI`). Todo eso queda en `tasks.md` como trabajo futuro; esta
entrega solo fija y testea el contrato de parseo (REQ-INV-2), que es la pieza reusable
sea cual sea el módulo final elegido.
