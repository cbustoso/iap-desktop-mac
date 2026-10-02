# Spec SSH — tasks (→ issues Linear)

- [x] T-SSH-1 (CBU-37, decidido: `swift-nio-ssh`, ver `transport-decision.md`) Spike stack SSH: `libssh2`/`libssh` (SPM-C) vs `swift-nio-ssh` (tabla design.md). Entregable: `specs/ssh/transport-decision.md` (formato `specs/tunnel/transport-decision.md`) + connect+auth+shell mínimo. Depende de: nada. Criterio: decisión registrada y spike compila+conecta contra mock o instancia real. → REQ-1
- [ ] T-SSH-2 `KeyProvisioner`: llaves efímeras RSA-3072/ECDSA P-256/384/521 (`CryptoKit`/`Security.framework`), export OpenSSH, `sign()` sin exponer privada. Depende de: nada (paralelo a T-SSH-1/3). Test: round-trip firma + formato OpenSSH contra vectores conocidos. Criterio: privada nunca serializada fuera del tipo. → REQ-2,7
- [ ] T-SSH-3 `CredentialResolver` + `OsLoginAuthorizer` + `MetadataKeyAuthorizer` (usa `GCPClient` para OS Login REST y metadata `ssh-keys`; valida username POSIX). Depende de: nada (paralelo a T-SSH-1/2). Test: mock `GCPClient` con `enable-oslogin` on/off + username inválido + caso security-key. Criterio: error tipado si OS Login exige security-key. → REQ-3,7
- [ ] T-SSH-4 `SshSession`/`SshChannel` (actor sobre el stream de `TunnelKit`: connect, auth publickey, open shell, write/resize/drain, buffer streaming UTF-8). Depende de: T-SSH-1 (stack elegido), T-SSH-2, T-SSH-3. Test: canal shell contra mock server SSH. Criterio: expone la conexión autenticada reutilizable (REQ-6). → REQ-1,4
- [ ] T-SSH-5 Integración `TerminalUI` (SwiftTerm + pestañas por instancia reutilizando `SessionAreaView` de `ExplorerUI`; resize propagado a `SshChannel`). Depende de: T-SSH-4. Test: feed/resize sin crash, paridad con `ExplorerUIPolishTests` de sesión. Criterio: una pestaña por instancia conectada. → REQ-4
- [ ] T-SSH-6 Reconexión vía capa IAP (estado `.lost` → "Reconnect" → nuevo túnel + nueva negociación SSH, misma pestaña). Depende de: T-SSH-4, T-SSH-5. Test: simular corte de stream de `TunnelKit` y verificar reconexión sin perder identificador de pestaña. Criterio: `splice` de `AuthKit` en curso no interrumpe canal activo. → REQ-5
- [x] T-SSH-7 Verificación de host key (TOFU/confirmación) + redacción de material criptográfico en OSLog. Depende de: T-SSH-2, T-SSH-4. Test: assert que no aparece texto de llave privada en logs; cambio de host key rechaza conexión. Criterio: cero secretos en logs (revisión manual + test). → REQ-7
      Decisión (CBU-43): `HostKeyVerifier` TOFU; huella SHA-256 formato OpenSSH en Keychain
      (`KeychainHostKeyStore`, servicio `com.iapdesktop.mac.ssh.known-hosts`, cuenta
      `project/zone/instance:puerto`; el puerto local del túnel es efímero, por eso la
      identidad es la instancia + puerto remoto). Cambio → `HostKeyVerificationError.changed`
      antes de autenticar; aceptar la nueva solo con `trust(_:)` explícito + reconexión (no se
      bloquea el event loop pidiendo confirmación). Fallo de Keychain → rechazo (fail closed).
      Logs: solo destino + resultado (`hostkey <resultado> host=…`), sin llaves ni huellas.
      Pendiente fuera de SSHKit: la App debe sustituir `InMemoryKnownHosts` por
      `HostKeyVerifier().policy(for:)` y ofrecer "Aceptar nueva identidad" en el error.

Fuera de estas tasks (épica aparte, `specs/sftp/`, P1/M3): explorador de archivos SFTP (`SftpChannel`/`SftpFileStream`/`SftpFileInfo`). Solo se exige que T-SSH-4 deje la conexión autenticada reutilizable para esa épica futura (REQ-6).

Secuencia: T-SSH-1 → (2 ∥ 3) → 4 → 5 → 6 → 7. T-SSH-2 y T-SSH-3 son paralelizables entre sí y no dependen del stack elegido en T-SSH-1.
