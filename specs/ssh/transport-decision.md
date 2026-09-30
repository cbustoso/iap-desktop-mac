# T-SSH-1 — Decisión de stack SSH (spike)

Fecha: 2026-09-30 · CBU-37 · `Sources/SSHKit/Transport/SSHTransport.swift`

## Decisión: SwiftNIO SSH (`swift-nio-ssh`)

Verificado contra el código fuente real (`swift-nio-ssh` 0.15.0, rev `3ec2814`, resuelto
por SPM) y contra el repo de `libssh2` (1.11.1). Corrige la tabla de partida de
`design.md` donde la verificación dio otra cosa:

| Requisito | `swift-nio-ssh` 0.15.0 | `libssh2` 1.11.1 (SPM-C) | `libssh` (SPM-C) |
|---|---|---|---|
| Compila y abre shell en este repo | ✅ spike + 4 tests contra mock NIOSSH en loopback | ❌ no compilado (ver "Alcance") | ❌ descartado |
| Motor criptográfico en macOS | ✅ swift-crypto → CryptoKit | ❌ backends solo OpenSSL / mbedTLS / libgcrypt / WinCNG / OS400 (sin CommonCrypto): hay que vendorizar mbedTLS u OpenSSL | ❌ idem (OpenSSL / libgcrypt / mbedTLS) |
| Integración async / NIO (coherente con `TunnelKit`) | ✅ `ChannelHandler` nativo; corre sobre cualquier `Channel` NIO | ❌ API bloqueante → wrapper tipo `SshWorkerThread` | ❌ idem |
| Auth `publickey` sin sacar la privada del proceso | ✅ `NIOSSHPrivateKey` en memoria (incl. `secureEnclaveP256Key`) | ✅ callback de firma | ✅ callback |
| Tipos de llave de usuario | ⚠️ ECDSA P-256/384/521 y Ed25519. **Sin RSA** (ni `ssh-rsa` ni `rsa-sha2-*`) | ✅ RSA + ECDSA + Ed25519 | ✅ |
| Certificados (OS Login) | ✅ `ecdsa-sha2-nistp{256,384,521}-cert-v01`, `ssh-ed25519-cert-v01` | ✅ | ✅ |
| Host keys | ⚠️ ECDSA + Ed25519, **sin RSA** | ✅ | ✅ |
| KEX | ✅ `curve25519-sha256(@libssh.org)`, `ecdh-sha2-nistp{256,384,521}` (sin `diffie-hellman-group*`) | ✅ | ✅ |
| Cifrados | ⚠️ **solo** `aes{128,256}-gcm@openssh.com` (sin chacha20, sin aes-ctr+hmac) | ✅ | ✅ |
| SFTP | ❌ no incluido; es un subsistema sobre un canal `session`, implementable encima (precedente: Citadel) | ✅ `libssh2_sftp_*` | ✅ |
| Licencia | Apache-2.0 | BSD-3 | ⚠️ LGPL-2.1 (enlazado estático en `.app` complicado) |
| Madurez | ⚠️ 0.x (minors pueden romper API) | ✅ madura | ✅ madura |

**Por qué gana `swift-nio-ssh`:** es la única opción que compila y abre shell hoy en este
repo sin vendorizar un motor criptográfico en C, y encaja sin adaptadores en la pila NIO
que ya usa `TunnelKit` (el handler SSH puede correr sobre el mismo tipo de `Channel`). Sus
huecos (RSA, cifrados, SFTP) no bloquean el caso IAP Desktop: las imágenes de GCE sirven
host keys ECDSA/Ed25519 y aceptan AES-GCM con la configuración por defecto de OpenSSH, y
REQ-SSH-2 ya admite ECDSA para la llave efímera.

**`libssh2` no se descarta por calidad sino por coste en macOS:** sin backend
CommonCrypto obliga a vendorizar libssh2 + mbedTLS (u OpenSSL, que no se puede enlazar
desde el sistema) como targets C, más un hilo dedicado tipo `SshWorkerThread`. Queda como
**plan B** si en vivo aparece un bloqueo real (host solo-RSA o política sin AES-GCM).
`libssh` no aporta nada sobre `libssh2` y añade LGPL.

## Entregado en este spike
- `SSHTransport.openShell(host:port:username:privateKey:hostKeyPolicy:terminal:term:)`:
  TCP → handshake → auth `publickey` → canal `session` con `pty-req` + `shell`.
  Conecta a `host:port`, como `SshConnection(IPEndPoint)` contra el listener local del
  túnel IAP en el original.
- `SSHShellSession`: `output: AsyncStream<Data>` (stdout+stderr), `write(_:)`,
  `resize(_:)` (`window-change`), `close()`.
- `SSHHostKeyPolicy.pinned(_:)` (y `acceptAnyForTesting`); TOFU real en T-SSH-7.
- Errores tipados `SSHTransportError.{hostKeyRejected, authenticationFailed,
  channelRejected, shellRejected}`: el motivo lo registran los delegados, porque NIOSSH
  solo propaga `ChannelError.eof` al caer la conexión.
- `Tests/SSHKitTests`: servidor SSH mock en proceso (NIOSSH rol servidor, host key
  Ed25519, shell falso con eco) y 4 tests: shell completo (pty 120×40, eco UTF-8, resize,
  `exit`), llaves P-384/P-521/Ed25519, llave no autorizada → `authenticationFailed`, host
  key inesperada → `hostKeyRejected`. Sin `sshd` del sistema ni red.
- Deps fijadas: `swift-nio-ssh` `.upToNextMinor(from: "0.15.0")` (resuelto 0.15.0). Efecto
  transitivo: `swift-nio-ssh` exige `swift-crypto < 5.0.0`, así que **swift-crypto bajó de
  5.0.0 a 4.5.2** (suite completa en verde tras el cambio). `swift-nio` sigue en 2.103.0.

## Alcance y desviación respecto a `design.md`
`design.md` pedía compilar un spike de **cada** candidato viable. No se compiló `libssh2`:
la tarea solo permitía añadir a `Package.swift` la dependencia elegida y en la máquina no
hay `libssh2` ni un OpenSSL enlazable (solo el de Homebrew). La comparación de `libssh2`
se hizo verificando su código fuente (backends, versión), no ejecutándolo. Si el plan B
llega a activarse, habrá que hacer ese spike.

## Riesgos abiertos (no bloquean T-SSH-2/3; revisar antes de T-SSH-4)
1. **Sin RSA**: T-SSH-2 (`KeyProvisioner`) debe generar ECDSA P-256 por defecto; RSA-3072
   de REQ-SSH-2 no es usable con este stack. Un host que solo ofrezca host key RSA no
   conectará.
2. **Solo AES-GCM**: un `sshd` endurecido que deshabilite GCM no negociará. Validar contra
   instancias reales (Debian/Ubuntu/COS/RHEL) en T-SSH-4.
3. **SFTP** (REQ-SSH-6, épica aparte): hay que implementar el cliente SFTP v3 sobre un
   canal `session` + `subsystem`. Esfuerzo propio o dependencia (Citadel); decidir en
   `specs/sftp/`.
4. **0.x**: fijado hasta el siguiente minor; cada subida es una revisión de API.
5. **Capa de transporte**: el spike abre TCP. T-SSH-4 debe correr el `NIOSSHHandler` sobre
   el stream de `TunnelKit`: vía el listener local del túnel (TCP a `127.0.0.1:{puerto}`,
   como el original) o conectando el handler directamente a un canal NIO puenteado con
   `RelayChannel`.
6. **Sin timeout de conexión/handshake** en el spike: T-SSH-4 debe añadirlo
   (`ConnectionTimeout` del original).
