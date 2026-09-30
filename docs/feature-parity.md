# Feature Parity — IAP Desktop (Windows) → IAP Desktop Mac

> Ref: https://github.com/GoogleCloudPlatform/iap-desktop (clonado 2026-09-30, rama main).
> La referencia es especificación funcional, NO código a portar línea a línea.
> Estado: **Fase 0 — pendiente de aprobación. No escribir código de producto hasta aprobar esta matriz + ADRs.**

Leyenda de prioridad: **P0** = MVP (M1/M2) · **P1** = M3 · **P2** = M4 / nice-to-have.
Riesgo: **B**ajo · **M**edio · **A**lto.

---

## 1. Autenticación (`Google.Solutions.Apis/Auth`, `IapDesktop.Application/Profile/Auth`)

| Funcionalidad | Módulo original | Pri. | Equivalente macOS | Riesgo |
|---|---|---|---|---|
| OAuth 2.0 installed-app + PKCE, loopback redirect (`LoopbackCodeReceiver`: HttpSys `HttpListener` o fallback `TcpListener` loopback, `http://localhost\|127.0.0.1:{puerto}/authorize/`) | `Auth/Gaia/GaiaOidcClient.cs`, `GaiaPkceOidcClient.cs`, `GaiaCodeFlow.cs`, `LoopbackCodeReceiver.cs`, `Platform/Net/Browser.cs` | P0 | `ASWebAuthenticationSession` + listener loopback (`NWListener` / `GCDWebServer`) en puerto efímero; PKCE S256 obligatorio. Nota: `GaiaPkceOidcClient` referencia `PkceGoogleAuthorizationCodeFlow` que no está en el repo (viene de `Google.Apis.Auth` 1.74.0) — validar versión o usar `AppAuth-iOS/macOS` | M |
| Scopes mínimos (`Cloud` solo; `Cloud+Email` si hace falta consentimiento, evita consent-unbundling) | `Auth/Scopes.cs`, `GaiaOidcClient.CreateFlow` | P0 | Misma lógica en `AuthKit` | B |
| Multi-cuenta (una sesión activa; cambio por `Splice()` que copia `UserCredential.Token` sin romper `ApiClient`s; evento `Reauthorized`; cambio Gaia↔STS descarta credencial offline) | `Auth/OidcClientBase.cs`, `OidcSessionBase.cs`, `IOidcSession.cs`, `Application/Profile/Auth/Authorization.cs` | P0 | `AuthKit`: `CredentialFacade` (actor) + interceptor propio sobre `URLSession`; patrón splice reimplementado (no existe `UserCredential` mutable en GTMAppAuth) | M |
| Store offline de refresh/id_token | `Auth/IOidcOfflineCredentialStore.cs` | P0 | Keychain (`kSecClassGenericPassword`), multi-issuer (Gaia + STS). DPAPI/registry de Windows no porta | B |
| Revocación (`revoke` endpoint, `RevokeGrantAsync`) y logout | `OidcSessionBase.cs`, `GaiaCodeFlow` (`token=/token`, `revoke=/revoke`) | P0 | `AuthKit` + limpieza Keychain | B |
| Workforce Identity Federation (headful OAuth vía auth-portal, `StsService.IntrospectToken`, `principal://…` → `WorkforcePoolIdentity`, `WorkforcePoolProviderLocator`) | `Auth/Iam/{WorkforcePoolClient,WorkforcePoolSession,AuthPortalCodeFlow,StsService,WorkforcePoolProviderLocator,WorkforcePoolIdentity}.cs` | P2 (M4) | Portable (REST). Mantener UX auth-portal y error `OsLoginNotSupportedForWorkloadIdentityException` | M |
| mTLS / BeyondCorp (cert `CN=Google Endpoint Verification` del store Windows, `SecureConnect`, endpoints `mtls.tunnel.cloudproxy.app`, `ServiceEndpointDirections {Public, PSC, mTLS}`) | `Auth/IDeviceEnrollment.cs`, `Application/Profile/Auth/DeviceEnrollment.cs`, `Client/PscAndMtlsAwareHttpClientFactory.cs`, `Client/ServiceEndpoint*.cs`, `Client/ClientServiceMtlsExtensions.cs` | P2 (M4) | Sin equivalente a Endpoint Verification en macOS; `SecIdentity` ≠ `X509Certificate2` exportable. v1: degradar a `Public`; `SystemPatch` (Host-header-over-WSS, User-Agent unrestrict) es Windows-only | A |
| Proxy corporativo (`WebRequest.DefaultWebProxy`, `NtlmResilientWebRequestHandler` reintenta 407 NTLM, `UseProxy=false` si PSC; en WebSocket `Options.Proxy=null` si PSC) | `Client/PscAndMtlsAwareHttpClientFactory.cs`, `Iap/IapInstanceTarget.cs` | P2 (M4) | `CFNetworkCopyProxiesForURL` + PAC para `https://oauth2/sts` y `wss://` (HTTP CONNECT). NTLM irrelevante en macOS | M |
| User-Agent propio (`UserAgent.cs`, `SystemPatch.UnrestrictUserAgentHeader`) | `Apis/Client/UserAgent.cs` | P1 | Header propio en REST + túnel; sin hack Windows | B |

APIs: `https://oauth2.googleapis.com/`, `https://sts.googleapis.com/`, `https://secureconnect-pa.mtls.clients6.google.com/`.

---

## 2. Project Explorer (`IapDesktop.Application/ToolWindows/ProjectExplorer`, `IapDesktop.Core/ProjectModel`)

| Funcionalidad | Módulo original | Pri. | Equivalente macOS | Riesgo |
|---|---|---|---|---|
| Jerarquía Cloud → Proyecto → Zona → Instancia (lazy load, `AsyncLock`, `ResourceManager` en paralelo + `LoadZonesAsync`, `aggregatedList` con `ReturnPartialSuccess`, filtra `Disks!=null`, `TraitDetector.DetectTraits`) | `Core/ProjectModel/{ProjectWorkspace,Nodes/CloudNode,ProjectNode,ZoneNode,InstanceNode}.cs`, `ProjectExplorerViewModel(.Nodes).cs` | P0 | SwiftUI `OutlineGroup` / `NSOutlineView` + `GCPClient` (Compute `aggregatedList`); caché actor. 403/404 → proyecto inaccesible con lista vacía | M |
| Añadir/eliminar proyectos (`ProjectPicker`), refresco total y por nodo, `RefreshSelectedNodeAsync`, `OpenInCloudConsole`, `ConfigureIapAccess` | `ProjectExplorerViewModel.cs`, `Windows/ProjectPicker/`, `Explorer/ToolWindows/Profile/AddProjectCommand.cs` | P0 | Idem SwiftUI + `NSWorkspace.open` consola | B |
| Estado de VM (imagen por OS + Running + Connected), eventos `SessionStarted/Ended`, `InstanceStateChangedEvent` | `ProjectExplorerViewModel.Nodes.cs`, `InstanceNode.cs` | P0 | ViewModel reactivo (`@Observable`) | B |
| Filtros: texto instancia (`OrdinalIgnoreCase` a nivel nodo) + toggles Linux/Windows (solo a nivel zona); colapsados persistidos (`CollapsedProjects` CSV) | `ProjectExplorerViewModel.cs`, `ProjectExplorerSettings.cs` | P0 | Búsqueda + filtros en memoria; persistencia `SettingsStore` | B |
| Favoritos / búsqueda global | — (no existe en original: solo filtro + colapsados) | P2 | Decisión producto: ¿paridad estricta (no favoritos) o mejora? Propuesta: P2 opcional | B |

> Ojo: `Extensions.Explorer/` solo contiene menús; el Explorer real está en `Application/`.

---

## 3. Túneles IAP TCP forwarding (`Google.Solutions.Iap`, `IapDesktop.Core/ClientModel/Transport`)

| Funcionalidad | Módulo original | Pri. | Equivalente macOS | Riesgo |
|---|---|---|---|---|
| WebSocket `relay.tunnel.cloudproxy.app` subprotocolo, `Origin: bot:iap-tunneler`, `KeepAlive 1min`, `wss://tunnel.cloudproxy.app/v4/` (+ `mtls.` si device cert), `connect?project&zone&instance&interface&port&_=guid` / `reconnect?sid&ack&zone`, Bearer access-token, `403→WebSocketConnectionDeniedException`, `404→SshRelayBackendNotFound` | `Iap/IapClient.cs`, `Iap/IapInstanceTarget.cs`, `Iap/Net/WebSocketStream.cs` | P0 | `TunnelKit` nativo (ver ADR-0002). `URLSessionWebSocketTask` no da control de `Host`/proxy/headers → probable `SwiftNIO` + `WebSocketKit` o `Network.framework` con framing manual | A |
| SSH Relay v4: tags `CONNECT_SUCCESS_SID=1, RECONNECT_SUCCESS_ACK=2, DATA=4, ACK=7, LONG_CLOSE=10`; close `4000…4033 NOT_AUTHORIZED, 4047 LOOKUP_FAILED, 4074 FAILED_TO_REWIND`; `SshRelayFormat` big-endian; `SshRelaySession` (reconnect ×2, `Sid`, `MaxReadDataPerAck=1MB`); `SshRelayStream` (cola unacked, `ResendUnacknoledged`, `ProbeConnectionAsync`, `MaxWriteSize/MinReadSize`) | `Iap/Protocol/{SshRelaySession,SshRelayStream,SshRelayFormat,SshRelayConstants}.cs`, `Iap/Net/{SingleReaderSingleWriterStream,NetworkStatistics,SocketStream,INetworkStream}.cs` | P0 | Port fiel a Swift (actors + `AsyncSequence`); tests C# (`TestSshRelay*`, `TestEchoOverIap*`, `TestHttpOverIap*`, `WebSocketServer` mock) son la spec → portar primero como tests `TunnelKit` | A |
| `IapListener`: `TcpListener` local + `IIapListenerPolicy.IsClientAllowed`, relay bidireccional, `NetworkStatistics`, eventos `ClientConnected/Disconnected/ConnectionFailed` | `Iap/IapListener.cs` | P0 | `NWListener` loopback + política allowlist | M |
| Pool de túneles (`Profile=protocol+policy+instance+targetPort+localEndpoint`, `Dictionary<Profile,Task<IapTunnel>>`, reutilización, `ProbeAsync` antes de `ListenAsync`, `PortFinder` determinista proyecto/zona/nombre/puerto con retry 5× `PortAccessDenied`, `TunnelsView`) | `Core/ClientModel/Transport/{IapTransportFactory,IapTunnel,ITransport,DirectTransportFactory,Policies/}.cs` | P0 | `TunnelKit.TunnelPool` (actor, ref-count) | M |
| Fallback `gcloud compute start-iap-tunnel` | — (no existe en original; propuesto en brief) | P1 | Opcional: `Process` a `gcloud` si túnel nativo falla; documentar flags y paridad de logs | B |
| Transporte directo (sin IAP) | `DirectTransportFactory.cs` | P1 | Soportar para VMs con IP pública (útil en dev) | B |

---

## 4. SSH (`Google.Solutions.Ssh`, `Extensions.Session/Protocol/Ssh`, `Terminal`)

| Funcionalidad | Módulo original | Pri. | Equivalente macOS | Riesgo |
|---|---|---|---|---|
| Stack SSH propio sobre `libssh2.Cng` (P/Invoke, `WSAEvent`, `SshWorkerThread`: `Thread` dedicado, `KeepAlive 5s`, `SocketWait 2s`, `ConnectionTimeout 15s`; `SshConnection`: cola `ISendOperation`, `OpenShellChannelAsync/OpenSftpChannelAsync`) | `Ssh/{SshConnection,SshWorkerThread,SshChannelBase,SshShellChannel}.cs`, `Ssh/Native/Libssh2*.cs` | P0 | `SSHKit`: `SwiftNIO SSH` (inmaduro, falta SFTP/hostkeys) o `libssh`/`libssh2` vía SPM-C + `Security.framework`/`CryptoKit`. `Thread` bloqueante → `EventLoop` + async/await | A |
| Terminal VT (`IPseudoTerminal`: `Resize/Write/Drain`, buffer 64KB, `StreamingDecoder` UTF-8), pestañas, copy/paste, temas, reconexión a nivel IAP (SSH no reconecta; resiliencia en `SshRelaySession` + `Splice()` auth) | `Ssh/SshShellChannel.cs`, `Terminal/` | P0 | `TerminalUI` sobre SwiftTerm; pestañas SwiftUI; reconexión = re-`connect?sid&ack` | M |
| Llaves: RSA-3072 + ECDSA P-256/384/521 (sin Ed25519), `AsymmetricKeySigner`, `RsaSigner/ECDSA signer`, `PublicKey.To/FromOpenSsh`, auth `publickey` por callback (privada nunca sale), `ECPointEncoding`, `AuthenticationChallenge` | `Ssh/Cryptography/*`, `Ssh/Format/SshReader,SshWriter.cs` | P0 | `CryptoKit`/`Security.framework`; evaluar añadir Ed25519 (mejora, no paridad) | M |
| OS Login (`ImportSshPublicKey`, `SignPublicKey` cert efímero, `GetLoginProfile`, `DeleteSshPublicKey`, `ListSecurityKeys`, `ProvisionPosixProfile`; `OsLoginProfile` orquesta llave efímera → Import o Sign; exige OS Login si habilitado; excepción 2FA security-key) vs metadata keys (`ssh-keys` en metadatos instancia/proyecto) | `Apis/Compute/OsLoginClient.cs`, `Session/Protocol/Ssh/{OsLoginProfile,PlatformCredentialFactory,EphemeralKeySigners,OsLoginCertificateSigner,ComputeMetadata,MetadataAuthorizedPublicKey*}.cs`, `Session/ToolWindows/SshKeys/AuthorizedPublicKeys*.cs` | P0 | `GCPClient` (OS Login REST) + `SSHKit` (llaves efímeras en Keychain); `SignPublicKey` + `ProvisionPosix` reimplementados | M |

---

## 5. SFTP (`Ssh/SftpChannel.cs`, `Session/Protocol/Ssh` + vistas SFTP en `Session`)

| Funcionalidad | Módulo original | Pri. | Equivalente macOS | Riesgo |
|---|---|---|---|---|
| Explorador de archivos sobre `SftpChannel`/`SftpFileStream`/`SftpFileInfo` (`ISftpChannel`), subida/descarga, drag&drop (vía RDP drive redirection y vistas sesión en original Windows) | `Ssh/{SftpChannel,SftpFileInfo,SftpFileStream}.cs`, `Ssh/Native/Libssh2Sftp*.cs` | P1 (M3) | `SFTPKit` sobre el mismo transporte `SSHKit`; UI SwiftUI con drag&drop nativo | M |

---

## 6. RDP (`Terminal/Controls/RdpClient.cs`, `Extensions.Session/Protocol/Rdp`, `ToolWindows/Session/RdpView*`)

| Funcionalidad | Módulo original | Pri. | Equivalente macOS | Riesgo |
|---|---|---|---|---|
| Cliente RDP vía MSTSC ActiveX (`AxMSTSCLib`/`MSTSCLib`, `Google.Solutions.Tsc.MsRdpClient`, `AxInterop.MSTSCLib.dll` en installer `Product.wxs`; fix `IMsRdpClientNonScriptable5_SendKeys`) | `Terminal/Controls/{RdpClient,RdpClient.ConnectionProperties,RdpClient.Marshalling,ClientBase}.cs` | P1 (M2) | Sin MSTSC en macOS → ver ADR-0003 (FreeRDP embebido vs lanzar "Windows App" con `.rdp`) | A |
| Parámetros: `Server/Domain/Username/ServerPort/Timeout 30s`, `ServerAuthenticationLevel 0/1/2`, NLA, RestrictedAdmin, `/admin`, ConnectionBar, redirecciones (clipboard/printer/smartcard/port/drive/device/audio 0/1/2, WebAuthn), `ColorDepth 16/24/32`, `KeyboardHookMode`, DPI scaling, auto-resize, hotkeys `Ctrl+Alt+F11`, error 516 → `RdsRedirectException` | `Session/Protocol/Rdp/{RdpParameters,RdpContext,RdpCredential,RdpCredentialCallback,WindowsUser}.cs`, `Session/ToolWindows/Session/RdpView.cs` | P1 | Congelar enums numéricos; mapear a perfil FreeRDP o a `.rdp` generado | A |
| Sesiones múltiples, tabs vs fullscreen | `Session/ToolWindows/Session/{SessionFactory,SessionViewBase,ClientViewBase,SessionContextFactory,SessionContextBase}.cs` | P1 | Pestañas SwiftUI + ventana fullscreen | M |

---

## 7. Credenciales Windows (API reset GCE)

| Funcionalidad | Módulo original | Pri. | Equivalente macOS | Riesgo |
|---|---|---|---|---|
| Generación: RSA-2048 `RSACng` OAEP-SHA256 (fallback SHA1), `POST` metadata `windows-keys {userName,email,expireOn+5min,modulus,exponent,addToAdministrators,hashFunction}`, poll `getSerialPortOutput(port=4)` buscando `modulus`, decrypt → `NetworkCredential`; permiso `compute.instances.setMetadata` | `Apis/Compute/WindowsCredentialGenerator.cs`, `Session/ToolWindows/Credentials/{NewCredentialsView{,Model},ShowCredentialsView{,Model},RdpCredentialEditor*}.cs` | P1 (M2) | `SecKeyCreateEncryptedData(.rsaEncryptionOAEPSHA256)`; polling serial con paginación `next?`, parse tolerante `\/`; secreto solo Keychain | M |

---

## 8. Settings con herencia proyecto → zona → instancia

| Funcionalidad | Módulo original | Pri. | Equivalente macOS | Riesgo |
|---|---|---|---|---|
| `MergedSettingsStore` (`Overlay`: default capa inferior, escribe en `Last`; `Policy`: read-only, escribe en `First`), `GroupPolicyAwareRepository` (`settings < userPolicy HKCU < machinePolicy HKLM`), `RegistrySettingsStore` (HKCU) | `Settings/{MergedSettingsStore,RegistrySettingsStore,DictionarySettingsStore,SettingsStoreBase,SettingBase,Collection/*}.cs` | P1 (M2) | `SettingsStore`: `UserDefaults (suite)` + Keychain (passwords, hoy DPAPI/`SecureString`) + MDM Managed Preferences para `Policy`; reimplementar `Merged Overlay/Policy`; migración claves `project/zone-/vm-` | M |
| Herencia conexión: layout plano `[base]/{project-id} + zone-{zone} + vm-{name}`; `GetInstanceSettings = Merged[Merged[Merged[Universe,Project],Zone],Instance]`; `GetZoneSettings`, `WriteAllSettings` solo `IsDirty`; `GetInstanceSettings(IapRdpUrl)` efímero (`foundInInventory=false`) | `Session/Settings/ConnectionSettingsRepository.cs`, `ConnectionSettingsService.cs` | P1 | Misma semántica en Swift | M |
| Esquema ~40 settings: `RdpUsername/Password/Domain/ConnectionBar/AuthenticationLevel/ColorDepth/AudioPlayback+Input/AutomaticLogon/NLA(+LocalRdpPolicy.IsPasswordSavingDisabled)/Timeout/Port 3389/Transport(IapTunnel|Direct)/Redirect*/HookWindowsKeys/RestrictedAdmin/SessionType/DpiScaling/DesktopSize`; `SshPort 22/Transport/PublicKeyAuthentication/Username/Password/Timeout`; `AppUsername/NLA`; `TerminalSettings`, `SshSettings` | `Session/Settings/ConnectionSettings.cs`, `TerminalSettings{,Repository}.cs`, `SshSettings.cs`, `LocalRdpPolicy.cs` | P1 | Congelar valores numéricos de enums; UI Settings SwiftUI | B |

---

## 9. Client applications (túneles a puertos arbitrarios)

| Funcionalidad | Módulo original | Pri. | Equivalente macOS | Riesgo |
|---|---|---|---|---|
| `AppProtocol(name,traits,remotePort,exe,args)` lanzado vía `IWin32ProcessFactory` (ej. SSMS), reutiliza credenciales RDP como `NetworkCredential`; `ForwardLocalPortCommand` (puerto remoto por diálogo → protocolo efímero) | `Session/ToolWindows/App/{AppCommands,ConnectAppProtocol*,ForwardLocalPortCommand}.cs`, `Session/Protocol/App/{AppProtocolContextFactory,Ssms,SsmsClient}.cs` | P1 (M3) | `NSWorkspace.open` + deep-links; exponer `127.0.0.1:puertoLocal` del `IapTunnel`; sin SSMS en macOS (sustituir por ejemplos: psql, SSMS vía equivalente, navegador) | M |

---

## 10. Operaciones de VM

| Funcionalidad | Módulo original | Pri. | Equivalente macOS | Riesgo |
|---|---|---|---|---|
| `ControlInstanceCommand(Start/Resume/Stop/Suspend/Reset)` → `CanStart/CanStop/CanSuspend/CanResume/CanReset` + confirm + `IJobService.RunAsync→ControlInstanceAsync` → `InstanceStateChangedEvent`; `JoinToActiveDirectoryCommand` (solo Windows+Running, Kerberos) | `Session/ToolWindows/InstanceControlCommands.cs`, `Apis/Compute/ComputeEngineClient.cs:ControlInstanceAsync` (`instances.start/stop/suspend/resume/reset` + `ExecuteAndAwaitOperationAsync`) | P1 (M2) | `GCPClient` + confirm SwiftUI; AD-join: P2 o descartar en v1 (evaluar en spec) | B |

---

## 11. Paneles: propiedades, serial, event log, inventario

| Funcionalidad | Módulo original | Pri. | Equivalente macOS | Riesgo |
|---|---|---|---|---|
| Propiedades de instancia (inspector) | `Session/ToolWindows/InstanceProperties/InstancePropertiesInspector*.cs` | P1 (M3) | Panel SwiftUI | B |
| Serial port output (`LoadAsync` + `TailAsync` poll 1s; `XtermReader` filtra VT100; `SerialPortReader`) | `Session/ToolWindows/SerialOutput/*`, `Apis/Compute/SerialPortReader.cs` (`instances.getSerialPortOutput`) | P1 (M3) | Idem + SwiftTerm para render | B |
| Event log = Cloud Audit Logs (`AuditLogClient.ProcessInstanceEventsAsync`: filtro `resource.labels.zone/instance_id OR labels.zone/instance_id + protoPayload.methodName + severity + resource.type=(gce_instance\|gce_project\|audited_resource) + timestamp>`, páginas de 1000, orden desc, retry backoff) — no es guest EventViewer | `Session/ToolWindows/EventLog/*`, `Session/Protocol/App/Auditing/*`, `Apis/Logging/LoggingClient.cs` | P1 (M3) | `GCPClient` Logging `entries.list` con filtro idéntico | M |
| Inventario = Guest Attributes (`GetGuestAttributesAsync(path=GuestOsInfo.GuestAttributePath)`; zona/proyecto = `ListInstances` + fan-out por instancia; filtra Windows para zona/proyecto) — NO usa `osconfig.googleapis.com` | `Session/Protocol/App/GuestOs/Inventory/*`, `Session/ToolWindows/PackageInventory/*` | P1 (M3) | Idem; throttle + paralelismo limitado | M |

---

## 12. Diagnóstico

| Funcionalidad | Módulo original | Pri. | Equivalente macOS | Riesgo |
|---|---|---|---|---|
| Sin test dedicado ni chequeo proactivo: solo `ProbeAsync` implícito, `IsAccessGrantedAsync(testIamPermissions)` fail-open, mensajes con links (`HelpTopics`: `CreateIapFirewallRule`, `IapAccess`, `ProxyConfiguration`); `35.235.240.0/20` no aparece en código (solo docs); `Extensions.Diagnostics/` es debug interno; `DiagnosticsCommands` solo genera HTML con links `iap-rdp://` | `Core/ClientModel/Transport/*`, `Application/Diagnostics/HelpTopics.cs`, `Core/HelpTopics.cs`, `Extensions.Diagnostics/*`, `Session/ToolWindows/Diagnostics/DiagnosticsCommands.cs` | P2 (M4) | Implementar desde cero en M4: `testIamPermissions(iap.tunnelInstances.accessViaIAP + compute.instances.get)`, chequeo firewall `firewalls.list` (rango IAP `35.235.240.0/20` puertos 3389/22), probe WebSocket, export OSLog | M |

---

## 13. Empaquetado / distribución / plataforma (no-funcional)

| Original (Windows) | Equivalente macOS | Pri. |
|---|---|---|
| WiX MSI (`installer/Product.wxs`), `AxInterop.MSTSCLib.dll`, x64/x86/ARM64 | Developer ID + Hardened Runtime + notarización; Universal Binary (arm64+x86_64); entitlements (cliente red saliente, listener loopback, Keychain); DMG/PKG; `Google.Solutions.Tsc` se elimina | P2 (M4, con base en M0) |
| WinForms + DockPanelSuite + MVVM (`Google.Solutions.Mvvm`) | SwiftUI + AppKit donde haga falta (ver ADR-0001) | P0 (M0) |
| Registry + GPO + DPAPI/`SecureString` + CNG | UserDefaults + MDM + Keychain + `Security.framework`/`CryptoKit` | P0 (M0) |
| NUnit + Moq + `WebSocketServer` mock | XCTest / Swift Testing + mock server protocolo IAP (port de `WebSocketServer` C#) + UI tests flujos críticos | P0 (M0) |
| kokoro + build.bat/ps1 | GitHub Actions runner macOS: build, SwiftLint/SwiftFormat, tests, firma/notarización en tags | P0 (M0) |
| `TraceSource` + logs | OSLog estructurado con niveles + exportación para soporte | P1 |

---

## Matriz de milestones propuesta

- **M0**: repo + SPM modular (`AuthKit GCPClient TunnelKit SSHKit TerminalUI SFTPKit RDPBridge SettingsStore App`), CI, ADRs, specs Auth/Explorer/Tunnel.
- **M1 (MVP P0)**: login Google, Explorer, túnel nativo, SSH + terminal + pestañas.
- **M2**: RDP + credenciales Windows + settings herencia + VM ops.
- **M3**: SFTP + client apps + serial + event log + inventario.
- **M4**: WIF + mTLS + proxy + diagnósticos + notarización + release 1.0.

## Puertas de aprobación

- [ ] Aprobar esta matriz (alcance P0/P1/P2 y riesgos A).
- [ ] Aprobar ADR-0001/0002/0003.
- [ ] Tras aprobación: crear specs `specs/<epic>/requirements.md|design.md|tasks.md` (Kiro) y luego código.
