# Spec SFTP — requirements (EARS)

Ref: `docs/feature-parity.md` §5 (SFTP) · Linear CBU-56 (épica CBU-14).
Origen C#: `Google.Solutions.Ssh/{ISftpChannel,SftpChannel,SftpFileInfo,SftpFileStream,
FilePermissions}.cs`, `Ssh/Native/Libssh2Sftp{Channel,FileChannel}.cs`.
Depende de `specs/ssh/requirements.md` (REQ-SSH-6: SFTP reutiliza la conexión SSH
autenticada; T-SSH-4, ya implementado en `Sources/SSHKit/Session/SshSession.swift`,
expone `openSubsystem(_:)`).

## REQ-SFTP-1 — Canal SFTP sobre la conexión SSH ya autenticada
- El sistema SHALL abrir el canal SFTP como un subsistema (`"sftp"`) de la misma
  `SshSession` ya autenticada (paridad: el original abre `SftpChannel` sobre el mismo
  `SshConnection` que el shell, sin segunda negociación de llaves/host key).
- El sistema SHALL NOT exigir una conexión SSH independiente para SFTP: si ya hay una
  pestaña de terminal abierta para una instancia, abrir el explorador de archivos de esa
  misma instancia SHALL reutilizar la `SshSession` existente (REQ-SSH-6).
- WHEN la sesión SSH subyacente está en estado `.lost` (ver `specs/ssh/design.md`,
  `SshLinkState`) THEN el sistema SHALL rechazar abrir un nuevo canal SFTP con error
  tipado, sin intentar una conexión paralela.

## REQ-SFTP-2 — Protocolo SFTP v3 sobre el subsistema
- El sistema SHALL implementar el protocolo SFTP versión 3 (`draft-ietf-secsh-filexfer-02`,
  la versión que negocia OpenSSH por defecto) sobre los bytes crudos del canal de
  subsistema (`SshDataChannel`, ya expuesto por `SSHKit`): framing de paquetes
  (`uint32 length` + `byte type` + payload), `SSH_FXP_INIT/VERSION`, `OPEN/CLOSE`,
  `READ/WRITE`, `LSTAT/FSTAT/SETSTAT`, `OPENDIR/READDIR`, `REMOVE/MKDIR/RMDIR/RENAME`,
  y las respuestas `STATUS/HANDLE/DATA/NAME/ATTRS`.
- La elección entre implementación propia del framing SFTP vs. adoptar una dependencia
  Swift existente (p. ej. Citadel, que ya implementa SFTP sobre `swift-nio-ssh`) SHALL
  quedar registrada en un spike previo (T-SFTP-1, análogo a
  `specs/ssh/transport-decision.md`); esta spec NO prescribe el ganador.
- El sistema SHALL soportar múltiples solicitudes en vuelo por canal (pipelining de
  `SSH_FXP_READ`/`SSH_FXP_WRITE` con distintos `request-id`), necesario para transferencias
  grandes con rendimiento aceptable (paridad: el original usa el mismo canal para streams
  concurrentes vía `Libssh2SftpFileChannel`).

## REQ-SFTP-3 — Explorador de archivos: listado y atributos
- El sistema SHALL listar el contenido de un directorio remoto (`SSH_FXP_OPENDIR` +
  `SSH_FXP_READDIR` hasta `SSH_FXP_STATUS(EOF)`), exponiendo por entrada: nombre, tipo
  (regular/directorio/symlink/otro — paridad `FilePermissions.IsDirectory/IsLink/
  IsRegular`), tamaño, UID/GID numéricos, fecha de último acceso y de última
  modificación (paridad `SftpFileInfo.{Name,Permissions,UserId,GroupId,
  LastAccessDate,LastModifiedDate,Size}`).
- El sistema SHALL interpretar los permisos POSIX completos del modo de archivo
  (`st_mode`): bits owner/group/other × read/write/execute, más el campo de tipo de
  archivo (regular, directorio, symlink, fifo, char/block device, socket) — paridad
  `FilePermissions` (`[Flags]` sobre `uint32`, igual bitmask que `st_mode` de POSIX).
- El sistema SHALL permitir navegar subdirectorios y volver al padre; la ruta remota
  actual SHALL mostrarse en la UI del explorador (M3).

## REQ-SFTP-4 — Subida y descarga (drag&drop AppKit, M3)
- El sistema SHALL soportar subida (local → remoto) y descarga (remoto → local) de
  archivos individuales y, si el tiempo lo permite, de directorios completos
  (recursión sobre `OPENDIR`/`MKDIR` en el remoto, o sobre `FileManager` en el local).
- El sistema SHALL soportar **drag&drop nativo de AppKit** como mecanismo principal de
  transferencia (M3): arrastrar archivos desde Finder a la vista del explorador SFTP
  sube el archivo; arrastrar una fila del explorador SFTP a Finder (o a otra app)
  descarga el archivo. Paridad funcional con el original (que solo tenía drag&drop vía
  redirección de unidades RDP, no SFTP nativo — este explorador es nuevo, no un port
  1:1).
- El sistema SHALL también ofrecer subida/descarga explícitas (menú contextual o
  botones), para los casos donde drag&drop no sea práctico (selección múltiple grande,
  automatización).
- WHEN se sube o descarga un archivo cuyo nombre ya existe en el destino THEN el
  sistema SHALL preguntar al usuario (sobrescribir / renombrar / cancelar) antes de
  truncar nada, salvo que la operación sea explícitamente una reanudación (REQ-SFTP-6).

## REQ-SFTP-5 — Apertura de archivos y permisos al crear
- El sistema SHALL abrir archivos remotos con los flags SFTP equivalentes a
  `FileMode`/`FileAccess` de .NET (paridad `ISftpChannel.CreateFileAsync(remotePath,
  mode, access, permissions)`): crear/truncar/abrir-si-existe, lectura/escritura/ambos.
- WHEN se crea un archivo nuevo en el remoto THEN el sistema SHALL enviar permisos
  POSIX explícitos en el `SSH_FXP_OPEN` (atributo `ATTRS` con `SSH_FILEXFER_ATTR_
  PERMISSIONS`), por defecto `0644` para archivos y `0755` para directorios creados
  (paridad con el comportamiento estándar de `sftp`/`scp`, el original expone
  `FilePermissions` como parámetro explícito del caller).

## REQ-SFTP-6 — Reanudación de transferencias
- El sistema SHALL soportar reanudar una descarga o subida interrumpida sin
  retransmitir desde el principio: para descargas, continuar `SSH_FXP_READ` desde el
  offset del archivo local parcial ya escrito; para subidas, abrir el remoto sin
  truncar (`FileMode` tipo "append"/"open or create" sin `TRUNC`) y continuar
  `SSH_FXP_WRITE` desde el tamaño remoto ya reportado por `LSTAT` (paridad: el stream
  SFTP del original soporta `Seek`, que es la primitiva sobre la que se construye la
  reanudación — `SftpFileStream` hereda de `Stream` y expone posición).
- WHEN la sesión SSH subyacente entra en `.reconnecting` (túnel IAP cortado, ver
  `specs/ssh/design.md`) durante una transferencia THEN el sistema SHALL pausar la
  transferencia (sin cancelarla) y reanudarla automáticamente desde el último offset
  confirmado al volver a `.connected`, sin reabrir el diálogo de "¿sobrescribir?".
- WHEN la sesión transiciona a `.lost` (reconexión agotada) THEN el sistema SHALL
  marcar la transferencia como pausada-recuperable (no fallida-terminal): el usuario
  puede reintentarla manualmente abriendo una nueva sesión, retomando desde el offset
  guardado.

## REQ-SFTP-7 — Seguridad y observabilidad
- El sistema SHALL NOT loguear rutas completas de archivos del usuario ni contenido de
  archivos transferidos; OSLog SHALL registrar como máximo el nombre base y el
  resultado (éxito/error) de cada operación.
- El sistema SHALL validar que la ruta remota de destino de una subida no intente
  escapar del directorio mostrado (sin resolución de `..` que escape fuera del árbol
  que el usuario está navegando), como medida defensiva básica de UI (el servidor SFTP
  remoto es la autoridad final de permisos; esto es solo higiene de UX).

## Trazabilidad
REQ-SFTP-1 → T-SFTP-2 · REQ-SFTP-2 → T-SFTP-1,2 · REQ-SFTP-3 → T-SFTP-3 ·
REQ-SFTP-4 → T-SFTP-5,6 · REQ-SFTP-5 → T-SFTP-2,4 · REQ-SFTP-6 → T-SFTP-4,7 ·
REQ-SFTP-7 → T-SFTP-8.
