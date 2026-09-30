# Spec SSH — requirements (EARS)

Ref: `docs/feature-parity.md` §4 (SSH) y §5 (SFTP, épica aparte) · Linear CBU-33.
Origen C#: `Google.Solutions.Ssh/*` (`SshConnection`, `SshWorkerThread`, `SshChannelBase`,
`SshShellChannel`, `Native/Libssh2*`, `Cryptography/*`) y
`Google.Solutions.IapDesktop.Extensions.Session/Protocol/Ssh/*`
(`PlatformCredentialFactory`, `OsLoginProfile`, `SshContext`, `MetadataAuthorizedPublicKeySet`).

## REQ-SSH-1 — Stack SSH (decisión diferida a spike)
- El sistema SHALL implementar el protocolo SSH (transporte, auth `publickey`, canal shell) en
  `SSHKit` sobre **una** de: `libssh2` (vía SPM-C, paridad directa con el original
  `libssh2.Cng`), `libssh` (SPM-C, API de más alto nivel) o **SwiftNIO SSH**
  (`swift-nio-ssh`, nativo Swift/async).
- La elección definitiva SHALL quedar registrada en un spike posterior
  (T-SSH-1, análogo a `specs/tunnel/transport-decision.md`) antes de escribir código de
  producto; esta spec NO prescribe el ganador.
- WHERE se use un binding C (`libssh2`/`libssh`) THEN el sistema SHALL envolver las
  llamadas bloqueantes en un `actor`/`Task` dedicado (equivalente a `SshWorkerThread`:
  hilo propio, cola `ISendOperation`, `KeepAlive` y `ConnectionTimeout` configurables) para
  no bloquear el `MainActor` ni el `EventLoop` de `TunnelKit`.
- WHERE se use SwiftNIO SSH THEN el sistema SHALL evaluar como riesgo bloqueante la
  ausencia de SFTP y de negociación completa de host keys en la librería antes de
  adoptarla (ver riesgo "A" en `docs/feature-parity.md` §4).

## REQ-SSH-2 — Llaves efímeras (RSA-3072 / ECDSA P-256/384/521)
- WHEN el usuario conecta por SSH THEN el sistema SHALL generar un par de llaves efímero
  (RSA-3072 o ECDSA P-256/384/521, sin Ed25519 en v1 — paridad con `AsymmetricKeySigner`)
  con `CryptoKit`/`Security.framework`, con validez acotada (p. ej. 30 min, equivalente a
  `PublicKeyValidity`).
- La clave privada SHALL NOT salir del proceso: la firma SHALL ocurrir vía callback
  (`publickey` auth callback), nunca serializando la privada a disco ni a logs.

## REQ-SSH-3 — Autorización: OS Login vs metadata keys
- WHEN se resuelve la credencial de una instancia THEN el sistema SHALL consultar si la
  instancia/proyecto tiene OS Login habilitado (metadata `enable-oslogin`).
- IF OS Login está habilitado THEN el sistema SHALL autorizar la llave efímera vía
  OS Login (`ImportSshPublicKey`/`SignPublicKey` cert efímero, `GetLoginProfile`) e
  IGNORAR cualquier llave en metadata; SHALL rechazar con error tipado si la instancia
  exige `security-key` (2FA hardware, fuera de alcance v1, paridad
  `OsLoginSkNotSupportedException`).
- IF OS Login NO está habilitado THEN el sistema SHALL publicar la llave pública en
  metadata de instancia o proyecto (`ssh-keys`), determinando el nombre POSIX
  (preferido por el usuario o derivado del email, paridad `LinuxUser.SuggestUsername`).
- El sistema SHALL exponer una configuración `KeyAuthorizationMethods` (instance-metadata /
  project-metadata / OS Login / all) análoga al original, para que capas superiores
  restrinjan el método permitido por política.

## REQ-SSH-4 — Terminal VT (SwiftTerm)
- El sistema SHALL renderizar la sesión shell sobre `SwiftTerm` en `TerminalUI`, alimentado
  por el canal shell de `SSHKit` (paridad `IPseudoTerminal`: `write/resize/drain`, buffer de
  recepción ≥64 KB, decodificación UTF-8 en streaming — `StreamingDecoder`).
- El sistema SHALL soportar múltiples pestañas de sesión (una por instancia conectada),
  copy/paste, y temas claro/oscuro heredados de `ExplorerUI`/`SessionAreaView`.
- WHEN el usuario redimensiona la ventana/pestaña THEN el sistema SHALL propagar el nuevo
  tamaño al pty remoto (`resize`) sin cerrar el canal.

## REQ-SSH-5 — Reconexión vía capa IAP (SSH no reconecta a nivel propio)
- El sistema SHALL delegar la resiliencia de red en `TunnelKit` (`RelaySession`/
  `RelayStream`, `reconnect?sid&ack`), NO en el protocolo SSH: si el WebSocket subyacente
  se corta, el canal SSH SHALL considerarse perdido y la UI SHALL ofrecer reconectar
  (nueva negociación SSH completa sobre un túnel IAP reconectado), paridad con el
  comentario del original ("SSH no reconecta; resiliencia en `SshRelaySession` + `Splice()`
  auth").
- WHEN la credencial (`AuthKit`) se re-autoriza (`splice`) durante una sesión SSH activa
  THEN el sistema SHALL NOT interrumpir el canal shell existente; solo las conexiones
  nuevas usan el token refrescado.

## REQ-SSH-6 — SFTP fuera de alcance (épica aparte)
- Esta spec SHALL NOT cubrir el explorador de archivos SFTP (`SftpChannel`,
  `SftpFileStream`, `SftpFileInfo`, drag&drop). SFTP SHALL especificarse en una épica
  independiente (`specs/sftp/`, P1/M3, ref. `docs/feature-parity.md` §5) que reutilice la
  conexión SSH ya autenticada de esta spec (mismo `SshConnection`, canal adicional).
- `SSHKit` SHALL exponer la conexión autenticada (o un punto de extensión) de forma que
  abrir un canal SFTP no requiera re-autenticar ni duplicar la gestión de llaves.

## REQ-SSH-7 — Seguridad y observabilidad
- El sistema SHALL NOT escribir llaves privadas, host keys aceptadas con secretos, ni
  contenido de sesión en logs. OSLog SHALL redactar cualquier material criptográfico.
- El sistema SHALL verificar el host key del servidor (TOFU o verificación contra
  metadata del proyecto si está disponible) y SHALL rechazar la conexión con error tipado
  si el host key cambia sin confirmación explícita del usuario.

## Trazabilidad
REQ-SSH-1 → T-SSH-1 · REQ-SSH-2 → T-SSH-2 · REQ-SSH-3 → T-SSH-3 · REQ-SSH-4 → T-SSH-4,5 ·
REQ-SSH-5 → T-SSH-6 · REQ-SSH-6 → (fuera de tasks.md, ver `specs/sftp/` futuro) ·
REQ-SSH-7 → T-SSH-2,3,7.
