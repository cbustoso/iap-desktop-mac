# Spec SFTP — design (`SFTPKit` + explorador en `ExplorerUI`/`TerminalUI`)

Ref: requirements.md · Origen C#: `Ssh/{ISftpChannel,SftpChannel,SftpFileInfo,
SftpFileStream,FilePermissions}.cs`, `Ssh/Native/Libssh2Sftp{Channel,FileChannel}.cs`.
Base real ya existente: `Sources/SSHKit/Session/SshSession.swift` (`openSubsystem(_:)`),
`Sources/SSHKit/Session/SshChannel.swift` (`SshDataChannel`), `SshLinkState`
(`Sources/SSHKit/Session/SshLinkState.swift`).

## Arquitectura (`SFTPKit`)

```
SshSession (SSHKit, ya autenticada)
  → openSubsystem("sftp") → SshDataChannel (bytes crudos)
       → SftpProtocolClient (framing SFTP v3: INIT/VERSION, request-id ↔ respuesta)
            → SftpChannel (API de alto nivel: listFiles/openFile/mkdir/remove/rename)
                 → SftpFileHandle (Stream-like: read/write/seek, soporta reanudación)
  → FileBrowserViewModel (ExplorerUI/TerminalUI) ← pestaña "Files" por instancia
       → drag&drop AppKit (NSFilePromiseProvider / NSDraggingSource / NSPasteboard)
```

- `SFTPKit` NO abre conexión SSH propia: recibe una `SshSession` ya conectada
  (inyectada desde `App`/`ExplorerUI`, misma instancia que la pestaña de terminal si
  existe) y llama `openSubsystem("sftp")` (REQ-SFTP-1). Si la sesión está `.lost`,
  `SftpChannel.open(over:)` SHALL fallar de inmediato con `SftpError.sessionLost` sin
  reintentar por su cuenta (la UI ofrece reabrir sesión, igual que SSH).
- La UI del explorador (M3) vive en `ExplorerUI`/`TerminalUI` como una pestaña más del
  mismo `SessionAreaView` usado por el terminal (`specs/ssh/design.md`), para que
  cambiar entre "Terminal" y "Files" de una instancia sea una pestaña, no una ventana
  nueva.

## Decisión de implementación del protocolo SFTP (a resolver en spike T-SFTP-1)

No se fija ganador en esta spec (REQ-SFTP-2). Comparación de partida, a verificar
contra código fuente real antes de decidir (mismo rigor que
`specs/ssh/transport-decision.md`):

| Criterio | Framing SFTP v3 propio sobre `SshDataChannel` | Dependencia Citadel (SFTP sobre `swift-nio-ssh`) |
|---|---|---|
| Reutiliza `SshSession`/`openSubsystem` ya implementado en `SSHKit` | ✅ directo | ⚠️ Citadel trae su propio cliente SSH; hay que verificar si expone solo el subsistema SFTP sobre un canal ya autenticado por `NIOSSHHandler`, o si exige su propia conexión | 
| Control fino de pipelining de requests (REQ-SFTP-2) | ✅ total | ⚠️ depende de la API expuesta |
| Esfuerzo de implementación | A (parser de paquetes, máquina de estados request-id↔respuesta, todos los tipos ATTRS) | B (si la integración con `SshSession` existente es viable) |
| Mantenimiento (dependencia externa 0.x/mayor externa a Apple) | — (código propio, control total) | ⚠️ releases y API fuera de nuestro control, como ya pasa con `swift-nio-ssh` |
| Precedente verificado en este repo | Ninguno aún | Ninguno aún (solo mencionado en `specs/ssh/transport-decision.md` como referencia, no probado) |

El spike (T-SFTP-1) SHALL: (1) verificar si Citadel puede operar sobre una
`NIOSSHHandler`/canal ya autenticado por `SshSession` sin duplicar la conexión (si no
puede, queda descartada sin más análisis); (2) si es viable, comparar esfuerzo contra
una implementación propia mínima (INIT/VERSION + OPEN/CLOSE/READ/WRITE/STAT + OPENDIR/
READDIR, suficiente para REQ-SFTP-3/4/5); (3) registrar la decisión en
`specs/sftp/transport-decision.md` (mismo formato que `specs/ssh/`) antes de T-SFTP-2.

## Protocolo SFTP v3 (si gana la implementación propia)

- `SftpPacket`: `encode()/decode()` del framing `uint32 length | byte type | payload`
  sobre los `Data` que entrega `SshDataChannel.output` (ya reensambla paquetes del
  canal SSH, pero SFTP necesita su propio reensamblado por `length` ya que un paquete
  SFTP puede llegar partido en varios mensajes del canal).
- `SftpRequestTable` (actor): asigna `request-id` incrementales, mapea cada ID a una
  `continuation`/`promise` pendiente; al llegar `STATUS/HANDLE/DATA/NAME/ATTRS` con ese
  ID, resuelve la espera correspondiente. Permite pipelining real (REQ-SFTP-2).
- `SftpAttributes`: traduce el bitmask `ATTRS` (`SIZE`, `UIDGID`, `PERMISSIONS`,
  `ACMODTIME`, `EXTENDED`) a/desde `SftpFileInfo` (ver abajo); solo rellena los campos
  presentes en el flag (paridad: el original expone `Length` lanzando si `SIZE` no
  está presente — aquí, propiedades `Optional`).
- `SftpChannel.open(over: SshSession) async throws -> SftpChannel`: hace
  `session.openSubsystem("sftp")`, envía `SSH_FXP_INIT(version: 3)`, espera
  `SSH_FXP_VERSION`, y queda listo para operaciones.

## `SftpFileInfo` (paridad con el original)

```swift
public struct SftpFileInfo: Sendable, Equatable {
    public let name: String
    public let permissions: PosixFileMode   // bitmask completo, ver abajo
    public var isDirectory: Bool { permissions.fileType == .directory }
    public var isSymbolicLink: Bool { permissions.fileType == .symbolicLink }
    public var isRegular: Bool { permissions.fileType == .regular }
    public let userID: UInt32?
    public let groupID: UInt32?
    public let lastAccessDate: Date?
    public let lastModifiedDate: Date?
    public let size: UInt64?
}

public struct PosixFileMode: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32
    public static let ownerRead = PosixFileMode(rawValue: 0o400)
    public static let ownerWrite = PosixFileMode(rawValue: 0o200)
    public static let ownerExecute = PosixFileMode(rawValue: 0o100)
    public static let groupRead = PosixFileMode(rawValue: 0o040)
    public static let groupWrite = PosixFileMode(rawValue: 0o020)
    public static let groupExecute = PosixFileMode(rawValue: 0o010)
    public static let otherRead = PosixFileMode(rawValue: 0o004)
    public static let otherWrite = PosixFileMode(rawValue: 0o002)
    public static let otherExecute = PosixFileMode(rawValue: 0o001)
    // Tipo de archivo: máscara 0xF000, igual semántica que st_mode/FilePermissions.
    public enum FileType: Sendable, Equatable {
        case fifo, characterDevice, directory, blockSpecial, regular, symbolicLink, socket, unknown
    }
    public var fileType: FileType { /* decodifica máscara 0xF000, congelado */ }
}
```

- `PosixFileMode` es un tipo **congelado** (paridad con la regla de `specs/settings/` y
  `specs/rdp/`): el bitmask de permisos (owner/group/other × rwx) nunca cambia de
  valor; `FileType` es un `enum` cerrado sin `default` que oculte un tipo no mapeado —
  cualquier valor de máscara no reconocido mapea explícitamente a `.unknown`, nunca
  lanza ni se descarta en silencio.

## `SftpChannel` — API de alto nivel

```swift
public actor SftpChannel {
    public static func open(over session: SshSession) async throws -> SftpChannel

    public func listFiles(atPath remotePath: String) async throws -> [SftpFileInfo]
    public func makeDirectory(atPath remotePath: String, permissions: PosixFileMode) async throws
    public func removeDirectory(atPath remotePath: String) async throws
    public func remove(atPath remotePath: String) async throws
    public func rename(fromPath: String, toPath: String) async throws
    public func attributes(atPath remotePath: String) async throws -> SftpFileInfo

    public func openFile(
        atPath remotePath: String, mode: SftpOpenMode, permissions: PosixFileMode
    ) async throws -> SftpFileHandle

    public func close() async
}

public enum SftpOpenMode: Sendable {
    case readOnly
    case writeCreateTruncate     // subida desde cero (sobrescribe)
    case writeCreateOrAppend     // subida con reanudación (REQ-SFTP-6, sin truncar)
}
```

- `listFiles`/`makeDirectory`/etc. mapean 1:1 a `OPENDIR+READDIR+CLOSE`,
  `MKDIR`, `RMDIR`, `REMOVE`, `RENAME`, `LSTAT` del protocolo (REQ-SFTP-3/5).
- `openFile` traduce `SftpOpenMode` a los flags `SSH_FXF_{READ,WRITE,CREAT,TRUNC,
  APPEND,EXCL}` del `SSH_FXP_OPEN` (paridad `FileMode`/`FileAccess` → flags nativos del
  original).

## `SftpFileHandle` — lectura/escritura con reanudación

```swift
public actor SftpFileHandle {
    public let remotePath: String
    public private(set) var offset: UInt64   // posición actual, soporta "seek" implícito

    public func read(upTo maxLength: Int) async throws -> Data   // vacío = EOF
    public func write(_ data: Data) async throws
    public func seek(to offset: UInt64)       // solo mueve el puntero local; sin red
    public func close() async
}
```

- `seek(to:)` no genera tráfico de red (paridad: SFTP v3 no tiene "seek" propio; cada
  `READ`/`WRITE` lleva su `offset` explícito en el paquete). Reanudar una transferencia
  (REQ-SFTP-6) es: abrir con `.readOnly`/`.writeCreateOrAppend`, `seek(to:
  bytesYaEscritos)`, y continuar leyendo/escribiendo desde ahí.
- `read`/`write` usan `SftpRequestTable` para enviar varias peticiones en vuelo
  (ventana configurable, p. ej. 8 peticiones de 32 KB) y mantener throughput aceptable
  sin esperar cada `DATA`/`STATUS` secuencialmente (REQ-SFTP-2).

## Transferencias y reanudación ante reconexión

- `FileTransfer` (modelo observable en la capa de UI): estado
  `{queued, transferring(bytesDone:bytesTotal:), paused(bytesDone:), completed,
  failed(SftpError)}`.
- Suscribe `SshSession.linkStateUpdates()` (ya existente, `specs/ssh/design.md`): al
  ver `.reconnecting`, pasa cada transferencia activa a `.paused(bytesDone:)` sin
  cerrar el `SftpFileHandle` ni el archivo local parcial; al volver `.connected`,
  reabre el canal SFTP (la sesión SSH es la misma, solo se reabre el subsistema si el
  canal de subsistema en sí se cerró) y continúa desde `bytesDone` (REQ-SFTP-6).
- Si `linkState` llega a `.lost`, la transferencia pasa a `.paused(bytesDone:)` de
  forma terminal para esa sesión: el usuario debe reabrir el explorador (nueva
  `SshSession`), momento en el que puede "Reanudar" la transferencia pendiente desde el
  offset guardado (persistido en memoria del `FileTransfer`, no en disco — si se cierra
  la app antes de reanudar, se pierde el progreso, aceptable para v1).

## Explorador de archivos (UI, M3)

- `FileBrowserViewModel` (`ExplorerUI`/`TerminalUI`, reutilizando patrones de
  `ExplorerViewModel`): árbol de directorios remoto, breadcrumb de ruta actual,
  columnas Nombre/Tamaño/Modificado/Permisos (formato `rwxr-xr-x` derivado de
  `PosixFileMode`).
- Drag&drop AppKit (REQ-SFTP-4):
  - **Subida**: la vista de lista implementa `NSDraggingDestination`; al recibir
    `NSFilenamesPboardType`/`NSPasteboard` con URLs de Finder, llama
    `SftpChannel.openFile(mode: .writeCreateTruncate)` por cada archivo soltado.
  - **Descarga**: cada fila expone un `NSFilePromiseProvider` que, al completarse el
    drop en Finder/otra app, dispara `SftpChannel.openFile(mode: .readOnly)` y escribe
    el contenido en la URL de destino que AppKit asigna.
  - Ambos casos reutilizan `FileTransfer` para mostrar progreso y permitir cancelar.
- Confirmación de sobrescritura (REQ-SFTP-4): antes de abrir con
  `.writeCreateTruncate` sobre un nombre existente, `listFiles`/`attributes` se
  consulta primero; si existe, se muestra un `NSAlert` con opciones Sobrescribir /
  Renombrar / Cancelar (patrón ya usado en VM Ops, ver `docs/usage.md` §8).

## Errores tipados
`SftpError.{sessionLost, protocolError(code: UInt32, message: String),
unsupportedVersion(negotiated: UInt32), fileNotFound, permissionDenied,
nameConflict, transferCancelled}` — mapea los códigos `SSH_FX_*` de `SSH_FXP_STATUS`
(paridad con el motivo de fallo que el original propaga desde `libssh2_sftp_last_error`).

## Tests primero
Portar como tests unitarios: framing de paquetes SFTP (encode/decode con vectores
conocidos de OpenSSH), `SftpRequestTable` con respuestas fuera de orden (pipelining),
`PosixFileMode.fileType` para cada máscara (`regular/directory/symbolicLink/fifo/
characterDevice/blockSpecial/socket/unknown`), y el flujo de reanudación con un mock de
`SshSession`/`SshDataChannel` que simula `.reconnecting`→`.connected` a mitad de una
transferencia (paridad conceptual con `Tests/SSHKitTests/SshReconnectTests.swift`).
