# Spec SFTP — tasks (→ issues Linear)

- [x] T-SFTP-1 Spike protocolo: framing SFTP v3 propio sobre `SshDataChannel` vs
      Citadel (tabla design.md); verificar si Citadel puede operar sobre una
      `SshSession` ya autenticada sin duplicar conexión. Entregable:
      `specs/sftp/transport-decision.md` (formato `specs/ssh/transport-decision.md`).
      Depende de: nada (usa `SSHKit` ya entregado, T-SSH-4). Criterio: decisión
      registrada antes de T-SFTP-2; si Citadel no puede reusar la conexión, se
      descarta sin más análisis. → REQ-2
- [x] T-SFTP-2 `SftpPacket`/`SftpRequestTable`/`SftpAttributes` (framing, pipelining
      por `request-id`, traducción de `ATTRS`) + `SftpChannel.open(over:)`
      (INIT/VERSION). Depende de: T-SFTP-1. Test: encode/decode con vectores conocidos
      de OpenSSH; respuestas fuera de orden resueltas al `request-id` correcto.
      Criterio: `open(over:)` falla con `.sessionLost` si `SshSession.linkState` ya es
      `.lost`, sin red. → REQ-1,2,5
- [ ] T-SFTP-3 `SftpChannel.listFiles`/`attributes`/`makeDirectory`/`remove`/
      `removeDirectory`/`rename` + `PosixFileMode` (congelado, `fileType` para las 7
      máscaras + `.unknown`). Depende de: T-SFTP-2. Test: `PosixFileMode.fileType` por
      máscara; `listFiles` contra mock OPENDIR/READDIR con paginación hasta EOF.
      Criterio: ningún caso de `FileType` usa `default` que oculte una máscara no
      mapeada. → REQ-3
- [ ] T-SFTP-4 `SftpFileHandle` (read/write/seek) + `SftpOpenMode` (flags
      SSH_FXF_* por modo) + reanudación básica (abrir sin truncar, `seek` al tamaño ya
      transferido). Depende de: T-SFTP-2. Test: subida/descarga simulada con corte a
      mitad + reanudación desde offset exacto, sin duplicar bytes. Criterio: `seek`
      nunca genera tráfico de red. → REQ-5,6
- [ ] T-SFTP-5 `FileBrowserViewModel` (M3): árbol de directorios, breadcrumb,
      columnas Nombre/Tamaño/Modificado/Permisos (`rwxr-xr-x` desde `PosixFileMode`).
      Depende de: T-SFTP-3. Test: navegación de subdirectorios y vuelta al padre con
      mock de `SftpChannel`. Criterio: reutiliza patrones de `ExplorerViewModel`
      (misma convención de IDs/filtrado). → REQ-3
- [ ] T-SFTP-6 Drag&drop AppKit (subida: `NSDraggingDestination` + Finder; descarga:
      `NSFilePromiseProvider`) + diálogo de conflicto Sobrescribir/Renombrar/Cancelar.
      Depende de: T-SFTP-4, T-SFTP-5. Test: UI test de drop simulado sube/descarga vía
      mock de `SftpChannel`; conflicto de nombre dispara el diálogo antes de truncar.
      Criterio: nunca trunca sin confirmación salvo reanudación explícita. → REQ-4
- [ ] T-SFTP-7 `FileTransfer` + integración con `SshSession.linkStateUpdates()`:
      pausa automática en `.reconnecting`, reanudación en `.connected`, pausa terminal
      en `.lost` con reanudación manual al reabrir sesión. Depende de: T-SFTP-4,
      `specs/ssh` T-SSH-6 (reconexión UI). Test: mock de `SshSession` que emite
      `.connected → .reconnecting → .connected` a mitad de una transferencia; verificar
      cero bytes duplicados/perdidos. Criterio: paridad conceptual con
      `Tests/SSHKitTests/SshReconnectTests.swift`. → REQ-6
- [ ] T-SFTP-8 Redacción en OSLog (rutas completas y contenido nunca logueados, solo
      nombre base + resultado) + validación defensiva de ruta de destino (sin `..` que
      escape del árbol navegado). Depende de: T-SFTP-3, T-SFTP-4. Test: assert sobre
      formateo/dump, paridad `T-AUTH-9`/`T-SET-10`/`T-RDP-9`. → REQ-7

Secuencia: T-SFTP-1 → T-SFTP-2 → (T-SFTP-3 ∥ T-SFTP-4) → T-SFTP-5 → T-SFTP-6; T-SFTP-7
depende de T-SFTP-4 y de que `specs/ssh` T-SSH-6 (reconexión UI) esté resuelto; T-SFTP-8
al cierre, en paralelo con T-SFTP-6/7.
