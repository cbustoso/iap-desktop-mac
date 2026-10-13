# T-SFTP-1 — Decisión de protocolo SFTP (spike)

Fecha: 2026-10-13 · GH-55 · `Sources/SFTPKit/`

## Decisión: framing SFTP v3 propio sobre `SshSession.openSubsystem("sftp")`

Criterio de corte de `design.md`: "si Citadel no puede reusar la conexión, se descarta sin
más análisis". Verificado contra el código fuente real de Citadel (rama `main` de
`orlandos-nl/Citadel`, `Package.swift`, `Sources/Citadel/Client.swift`,
`Sources/Citadel/SFTP/Client/SFTPClient.swift`):

| Requisito | Framing propio sobre `SshDataChannel` | Citadel |
|---|---|---|
| Reutiliza la `SshSession` ya autenticada (REQ-SFTP-1) | ✅ `openSubsystem("sftp")` en la misma conexión (test contra mock SSH: el servidor ve el subsistema `sftp` y la sesión sigue viva) | ❌ `SFTPClient` solo nace de `SSHClient.openSFTP()` (`init`/`setupChannelHanders` son `fileprivate`). Todos los `SSHClient.connect(...)` (incluidos `connect(on: Channel, …)`) hacen **su propio** handshake + autenticación: no aceptan un `NIOSSHHandler` ni una sesión autenticada fuera. Reusarlo = segunda conexión SSH por otro stream del túnel |
| Compatible con nuestro `swift-nio-ssh` | ✅ sin dependencias nuevas | ❌ depende de un **fork** (`Wellz26/swift-nio-ssh` `0.3.4..<0.4.0`); nosotros usamos `apple/swift-nio-ssh` 0.15.0. Ambos exportan el módulo `NIOSSH`: SwiftPM no puede tener los dos en el mismo grafo |
| Pipelining por `request-id` (REQ-SFTP-2) | ✅ `SftpRequestTable` (control total) | — (no evaluado: descartado antes) |
| Esfuerzo | A, acotado: framing + ATTRS + tabla ya entregados aquí (~680 líneas de código, sin contar tests) | — |

**Citadel queda descartada por los dos motivos a la vez**: no puede reusar la conexión
(criterio de corte) y además su fork de `swift-nio-ssh` choca con el nuestro. No se
compiló: la red de la máquina de build está bloqueada para SwiftPM y el criterio de corte
ya decide; la verificación es de código fuente, como en `specs/ssh/transport-decision.md`.

## Entregado (T-SFTP-2)
- `SftpPacket` + `SftpFramer`: `uint32 length | byte type | payload`, reensamblado de
  paquetes partidos o pegados en mensajes del canal SSH; `length` > 256 KiB
  (`SFTP_MAX_MSG_LENGTH` de OpenSSH) o tipo desconocido → `.malformedPacket` antes de
  reservar memoria.
- `SftpAttributes`: bitmask `SIZE|UIDGID|PERMISSIONS|ACMODTIME|EXTENDED`, campos
  opcionales; ida y vuelta byte a byte con OpenSSH.
- `SftpResponse`/`SftpStatus`/`SftpName`/`SftpVersion` y `SftpError` (códigos `SSH_FX_*`
  → `.fileNotFound`/`.permissionDenied`/`.sessionLost`/`.protocolError`).
- `SftpRequestTable`: ids incrementales, respuestas fuera de orden, respuestas que llegan
  antes del `wait` (sin carrera), `failAll` al cerrar. Clase con lock en vez del actor del
  borrador de `design.md`: el lector del canal resuelve sin saltos de aislamiento.
- `SftpChannel.open(over:)`: `.lost`/`.closed` → `.sessionLost` **sin pedir el
  subsistema**; INIT(3) → VERSION con plazo (`.timeout`); versión ≠ 3 →
  `.unsupportedVersion`; extensiones expuestas (`posix-rename@openssh.com`, …).
  `realPath(_:)` como primera operación (ejercita el pipelining de extremo a extremo).
- Vectores: capturados del `sftp-server` de OpenSSH que trae macOS
  (`/usr/libexec/sftp-server`): VERSION con 11 extensiones, ATTRS de un fichero 0100644,
  STATUS `NO_SUCH_FILE`.

## Riesgos abiertos
1. **Nombres de fichero no UTF-8**: SFTP v3 transporta bytes; hoy se decodifican como
   UTF-8 con sustitución (U+FFFD). T-SFTP-3 debe conservar los bytes crudos para poder
   operar sobre esos ficheros.
2. **`.reconnecting`** permite abrir (el túnel se reanuda y el canal sigue siendo el
   mismo, CBU-42); si la reanudación falla, las peticiones pendientes fallan con
   `.channelClosed` al cerrarse el canal. La pausa/reanudación de transferencias es
   T-SFTP-7.
3. **Ventana de pipelining** sin límite en `SftpChannel.request`: T-SFTP-4 debe acotarla
   (p. ej. 8 × 32 KiB) para no saturar la ventana del canal SSH.
4. **Sin validación contra una VM real** todavía (solo `sftp-server` local vía stdin y el
   mock SSH, que hace eco del subsistema).
