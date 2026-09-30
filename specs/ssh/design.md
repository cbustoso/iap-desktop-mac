# Spec SSH — design (`SSHKit` + `TerminalUI`)

Ref: requirements.md · Origen C#: `Ssh/{SshConnection,SshWorkerThread,SshChannelBase,
SshShellChannel}.cs`, `Ssh/Native/Libssh2*.cs`, `Ssh/Cryptography/*`,
`Extensions.Session/Protocol/Ssh/{PlatformCredentialFactory,OsLoginProfile,SshContext,
MetadataAuthorizedPublicKeySet}.cs`, `Terminal/Controls/SshShellClient.cs`.

## Arquitectura (`SSHKit`)

```
KeyProvisioner (ephemeral RSA-3072/ECDSA, CryptoKit/Security.framework)
  → CredentialAuthorizer (OS Login vía GCPClient | metadata keys vía GCPClient)
  → SshSession (actor: connect/authenticate/openShell) ── sobre stream de TunnelKit
        (WebSocketTransport → RelayChannel, ver specs/tunnel/design.md)
  → SshChannel (shell: write/resize/drain, buffer streaming UTF-8)
  → TerminalUI (SwiftTerm) ← pestañas por instancia
```

- `SSHKit` NO abre su propio socket TCP: consume el stream ya multiplexado por
  `TunnelKit` (túnel IAP a `127.0.0.1:{puerto}` o el `RelayChannel` directo), igual que el
  original abre `SshConnection(IPEndPoint, …)` contra el listener local de IAP.
- El protocolo SSH corre **encima** del transporte de `TunnelKit`; `SSHKit` no conoce
  WebSocket/relay, solo un `AsyncSequence<UInt8>`/`ByteBuffer` bidireccional (misma
  separación de capas que `Ssh` vs `Iap` en el original).

## Decisión de stack SSH (a resolver en spike T-SSH-1)

> **Resuelto (CBU-37): `swift-nio-ssh`.** Ver `specs/ssh/transport-decision.md`, que
> corrige esta tabla con lo verificado en el código fuente (sin RSA, solo AES-GCM, SFTP
> implementable encima). La tabla de abajo se conserva como punto de partida.

No se fija ganador en esta spec (REQ-SSH-1). Comparación de partida para el spike,
verificada contra el código fuente real antes de decidir (mismo rigor que
`specs/tunnel/transport-decision.md`):

| Criterio | `libssh2` (SPM-C) | `libssh` (SPM-C) | SwiftNIO SSH (`swift-nio-ssh`) |
|---|---|---|---|
| Paridad directa con el original (`libssh2.Cng`) | ✅ mismo motor, API C similar a `Native/Libssh2*.cs` | ⚠️ motor distinto, mismo protocolo | ⚠️ reimplementación Swift, no reusa lógica C# |
| SFTP (canal adicional, épica aparte) | ✅ `libssh2_sftp_*` maduro | ✅ soporta SFTP | ❌ sin soporte SFTP en la librería (bloqueante para REQ-SSH-6 a futuro) |
| Auth `publickey` con firma por callback (privada no sale del proceso) | ✅ callback nativo | ✅ callback nativo | ✅ soporta `NIOSSHPrivateKey` custom |
| Host keys (ECDSA/RSA, verificación) | ✅ | ✅ | ⚠️ cobertura de tipos de host key limitada, verificar versión |
| Integración async/await nativa (sin hilo bloqueante propio) | ❌ requiere wrapper tipo `SshWorkerThread` (actor + hilo dedicado) | ❌ igual que libssh2 | ✅ `EventLoop`/`Channel` nativo, coherente con `TunnelKit` (NIO) |
| Madurez/mantenimiento en Swift (bindeo, builds, CI) | ⚠️ requiere target C + linking OpenSSL/mbedTLS | ⚠️ igual, dependencia adicional | ✅ paquete Swift puro, sin binding C |
| Riesgo global (`docs/feature-parity.md` §4) | M (binding C, wrapper de hilo) | M (idem) | A (inmadurez, falta SFTP) |

El spike (T-SSH-1) SHALL: (1) compilar un spike mínimo de cada candidato viable
(probablemente `libssh2` y `swift-nio-ssh`, descartando `libssh` si no aporta ventaja
sobre `libssh2`), (2) probar auth `publickey` + apertura de canal shell contra una
instancia real o mock, (3) registrar la decisión en
`specs/ssh/transport-decision.md` (mismo formato que `specs/tunnel/`) antes de T-SSH-3.

## Llaves efímeras y autorización

- `KeyProvisioner`: genera `SecKey`/`P256.Signing.PrivateKey` (según tipo elegido) en
  memoria (no en Keychain persistente — la llave es efímera y vive solo mientras dure la
  sesión, paridad con `AsymmetricKeySigner` transitorio); expone `PublicKey`
  (`RsaPublicKey`/`EcdsaPublicKey` → formato OpenSSH, paridad `PublicKey.ToOpenSsh`) y un
  `sign(challenge:)` que nunca expone bytes privados fuera del tipo.
- `CredentialAuthorizer` (protocolo con dos implementaciones):
  - `OsLoginAuthorizer`: usa `GCPClient` (OS Login REST: `importSshPublicKey` /
    `signSshPublicKey`, `getLoginProfile`) para importar o firmar un certificado efímero;
    si la instancia exige `security-key` (2FA hardware) SHALL fallar con
    `SshError.osLoginSecurityKeyNotSupported` (paridad `OsLoginSkNotSupportedException`).
  - `MetadataKeyAuthorizer`: publica la llave pública en `ssh-keys` (metadata de instancia
    o proyecto, decidido por `GCPClient` según permisos IAM) con el usuario POSIX
    resuelto (`preferredUsername` o derivado del email de `AuthKit`, paridad
    `LinuxUser.SuggestUsername`); valida el username contra el patrón POSIX antes de
    publicar (paridad `LinuxUser.IsValidUsername`).
  - `CredentialResolver`: consulta `enable-oslogin` en metadata de la instancia
    (vía `GCPClient`) y elige el authorizer; SHALL fallar tipado si OS Login está
    forzado pero no permitido por política (`KeyAuthorizationMethods`, paridad
    `PlatformCredentialFactory.CreateCredentialAsync`).

## Terminal VT (`TerminalUI` sobre SwiftTerm)

- `SshChannel` (dentro de `SSHKit`): expone `write(Data)`, `resize(cols:rows:)`,
  `output: AsyncStream<Data>` y `closed: AsyncStream<CloseReason>`; buffer de recepción
  ≥64 KB y decodificación UTF-8 en streaming (paridad `StreamingDecoder`, evita romper
  secuencias multi-byte partidas entre paquetes).
- `TerminalUI`: envuelve `SwiftTerm.TerminalView`, conecta `output` → `feed(byteArray:)` y
  las pulsaciones de usuario → `SshChannel.write`; una pestaña (`NSTabViewItem` o
  `SessionAreaView`, ver `ExplorerUI`) por instancia conectada, reutilizando el patrón de
  `SessionAreaView.openSession/closeSession` ya existente en `ExplorerUI`.
- Resize de ventana/pestaña SHALL invocar `SshChannel.resize` sin cerrar el canal
  (paridad `IPseudoTerminal.Resize`).

## Reconexión vía capa IAP

- `SSHKit` NO implementa retry/reconnect propio a nivel de protocolo SSH: si el stream de
  `TunnelKit` se cierra (túnel caído), `SshSession` SHALL transicionar a estado `.lost` y
  notificar a `TerminalUI`, que ofrece "Reconnect" al usuario.
- "Reconnect" SHALL disparar: nuevo túnel IAP (`TunnelKit` maneja `reconnect?sid&ack` a su
  nivel si el `Sid` sigue vivo) → nueva negociación SSH completa (nuevo handshake, misma
  llave efímera si aún es válida, o nueva llave si expiró) → nuevo `SshChannel`; la pestaña
  de `TerminalUI` se conserva (mismo identificador de sesión), solo se reemplaza el canal
  subyacente.
- Cambios de credencial (`AuthKit.splice`) durante una sesión activa SHALL NOT afectar el
  canal shell en curso; solo aplican a autorizaciones nuevas (paridad con el comentario
  del original: "SSH no reconecta; resiliencia en `SshRelaySession` + `Splice()` auth").

## Errores tipados
`SshError.{keyGenerationFailed, osLoginSecurityKeyNotSupported, osLoginRequired,
metadataPublishDenied, invalidUsername, hostKeyChanged(expected:got:), authenticationFailed,
channelClosed(reason:), transportLost}` con `HelpTopic` cuando aplique (paridad
`OsLoginSkNotSupportedException` + `HelpTopics`).

## Alcance excluido (ver REQ-SSH-6)
SFTP (`SftpChannel`/`SftpFileStream`/`SftpFileInfo`, UI drag&drop) se especifica en una
épica aparte (`specs/sftp/`, P1/M3). Este diseño solo garantiza que `SshSession` expone la
conexión autenticada para que esa épica abra un canal SFTP adicional sin reautenticar.
