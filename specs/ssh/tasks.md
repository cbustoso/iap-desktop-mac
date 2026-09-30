# Spec SSH — tasks (→ issues Linear)

- [ ] T-SSH-1 Spike stack SSH: comparar `libssh2`/`libssh` (SPM-C) vs `swift-nio-ssh`
      (headers/auth publickey/host-keys/SFTP futuro, ver tabla en design.md). Entregable:
      `specs/ssh/transport-decision.md` (formato `specs/tunnel/transport-decision.md`) +
      spike mínimo de connect+auth+shell contra mock o instancia real. → REQ-1
- [ ] T-SSH-2 `KeyProvisioner`: llaves efímeras RSA-3072/ECDSA P-256/384/521
      (`CryptoKit`/`Security.framework`), export OpenSSH pública, `sign()` sin exponer
      privada. Test: round-trip firma + formato OpenSSH contra vectores conocidos. →
      REQ-2, REQ-7
- [ ] T-SSH-3 `CredentialResolver` + `OsLoginAuthorizer` + `MetadataKeyAuthorizer` (usa
      `GCPClient` para OS Login REST y metadata `ssh-keys`); validación username POSIX;
      error tipado si exige security-key. Test: mock `GCPClient` con
      `enable-oslogin` on/off + username inválido. → REQ-3, REQ-7
- [ ] T-SSH-4 `SshSession`/`SshChannel` (actor sobre el stream de `TunnelKit`: connect,
      auth publickey, open shell, write/resize/drain, buffer streaming UTF-8). Depende de
      la decisión de T-SSH-1. Test: canal shell contra mock server SSH. → REQ-1, REQ-4
- [ ] T-SSH-5 Integración `TerminalUI` (SwiftTerm + pestañas por instancia, reutilizando
      `SessionAreaView` de `ExplorerUI`; resize propagado a `SshChannel`). Test: UI test
      feed/resize sin crash, paridad con `ExplorerUIPolishTests` de sesión. → REQ-4
- [ ] T-SSH-6 Reconexión vía capa IAP (estado `.lost` → "Reconnect" → nuevo túnel + nueva
      negociación SSH, misma pestaña). Test: simular corte de stream de `TunnelKit` y
      verificar reconexión sin perder identificador de pestaña. → REQ-5
- [ ] T-SSH-7 Verificación de host key (TOFU/confirmación) + redacción de material
      criptográfico en OSLog. Test: assert que no aparece texto de llave privada en logs;
      cambio de host key rechaza conexión. → REQ-7

Fuera de estas tasks (épica aparte, `specs/sftp/`, P1/M3): explorador de archivos SFTP
(`SftpChannel`/`SftpFileStream`/`SftpFileInfo`). Solo se exige que T-SSH-4 deje la
conexión autenticada reutilizable para esa épica futura (REQ-6).

Secuencia: T-SSH-1 → 2 → 3 → 4 → 5 → 6 → 7. T-SSH-2 y T-SSH-3 pueden ir en paralelo tras
T-SSH-1 (no dependen entre sí ni del stack elegido).
