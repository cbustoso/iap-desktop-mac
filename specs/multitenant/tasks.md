# Spec Multi-tenant — tasks (→ issues Linear/GH)

- [ ] T-MT-1 `ProfileID`/`ProfileDescriptor`/`ProfileStore` (`AuthKit`, nuevo archivo):
      índice de metadata no sensible en `UserDefaults.standard["profiles.index"]`;
      helpers `keychainService(for:suffix:)`/`userDefaultsSuite(for:component:)`.
      Depende de: nada. Test: round-trip `list`/`upsert`/`remove`; dos perfiles con el
      mismo email pero `profileID` distinto no colisionan; `redactedAccount` nunca
      contiene el email completo para issuer STS. Criterio: cero dato sensible (token,
      email completo de Gaia es aceptable como ya se muestra hoy, pero ningún
      `refreshToken`/`idToken`) persistido en el índice. → REQ-1,2,6
- [ ] T-MT-2 Namespacing de `KeychainStore`/`ClientIDStore`/`KeychainSettingsStore`/
      `KeychainHostKeyStore`/`UserDefaultsSettingsStore` por `profileID` (aplicar
      `ProfileStore.keychainService`/`userDefaultsSuite` a cada constructor existente,
      sin cambiar su API — todos ya aceptan `service`/`suiteName` inyectable). Depende
      de: T-MT-1. Test: dos perfiles con `CredentialFacade` namespaced distinta no
      comparten Keychain (`accounts()` de uno no ve al otro); borrar el Keychain de un
      perfil no afecta al otro; mismo patrón para `KeychainHostKeyStore` (huellas SSH)
      y `KeychainSettingsStore` (contraseñas RDP). Criterio: aislamiento verificado con
      servicios reales de Keychain en test (efímero, como ya hacen
      `Tests/AuthKitTests`). → REQ-3
- [ ] T-MT-3 `ProfileSession` (`Sources/App`, nuevo archivo): extrae el wiring que hoy
      vive en `AppDelegate` (`credentialFacade`, `workspace`, `vmClient`,
      `terminalTabs`, `sftpBrowsers`, `sshSessions`, `wireSshConnect`/`wireRdpConnect`/
      `wireSftpBrowse`, cálculo de `accessToken`) a una clase por perfil, parametrizada
      por `ProfileID`. Depende de: T-MT-1, T-MT-2. Test: dos `ProfileSession` con
      `profileID` distinto no comparten ninguna propiedad en memoria (assert de
      identidad de objeto, no solo de valor); `knownProjectIDs` de cada uno lee/escribe
      su propia `suiteName`. Criterio: ningún `static`/global compartido entre
      instancias de `ProfileSession`. → REQ-1,2
- [ ] T-MT-4 `ProfileCoordinator` (`Sources/App`, nuevo archivo): `activate(_:)` (crea o
      enfoca ventana), `createProfile()`, `removeProfile(_:)`, `windowDidClose(for:)`.
      Depende de: T-MT-3. Test: `activate` sobre un perfil ya abierto NO crea una
      `ProfileSession` nueva (misma identidad de objeto); `activate` sobre dos perfiles
      distintos produce dos `ProfileSession`/ventanas independientes; cerrar la ventana
      de uno no toca el `sshSessions`/`terminalTabs` del otro (mock de sesiones SSH
      activas en ambos, assert de que solo las del cerrado se limpian). Criterio: cero
      interferencia cruzada verificada con sesiones mock en ambos perfiles
      simultáneamente. → REQ-2,4
- [ ] T-MT-5 Menú `Profiles` en `Sources/App/App.swift` (lista dinámica desde
      `ProfileStore.list()`, `Add profile…`, `Remove profile…` con confirmación
      `NSAlert`) + indicador de perfil en cada ventana (reutilizando
      `showAccount(email:)`/`accountText` ya existente en `ExplorerWindowController`,
      sin tocar `ExplorerUI`). Depende de: T-MT-4. Test: menú refleja altas/bajas de
      perfiles en caliente; seleccionar un perfil invoca
      `ProfileCoordinator.activate(_:)` con el `profileID` correcto. Criterio: ningún
      cambio de API pública en `ExplorerUI` (solo consumo de lo ya expuesto). → REQ-2,3
- [ ] T-MT-6 Confirmación de aislamiento end-to-end (REQ-4): test de integración con dos
      `ProfileSession` reales (mock de `SshSession`/`TerminalBackend`, sin red) que abre
      sesiones SSH simuladas en ambos perfiles, cambia el foco varias veces y revoca la
      sesión de uno (`CredentialFacade.revoke()`), verificando que el `Reauthorized` del
      perfil revocado NUNCA llega al `GCPClient`/interceptor del otro perfil. Depende
      de: T-MT-3, T-MT-4. Criterio: cero fuga de eventos `Reauthorized` entre perfiles.
      → REQ-4
- [ ] T-MT-7 `ProfileMigrator.migrateLegacySingleProfileIfNeeded()` (`AuthKit` o
      `Sources/App`, a decidir en implementación: depende de si necesita tipos de
      `AppKit` — probablemente `AuthKit` puro, ya que solo toca Keychain/UserDefaults).
      Depende de: T-MT-1, T-MT-2. Test: estado legado con cuenta + `knownProjectIDs` +
      override de client ID migra completo y verificado; estado legado vacío migra a
      perfil "pendiente de login" sin error; fallo simulado de Keychain en el paso de
      verificación NO marca la migración completa y NO borra nada legado (assert de que
      las ubicaciones legadas siguen intactas); ejecutar el migrador dos veces es
      idempotente (segunda vez es no-op). Criterio: cero pérdida de datos en el peor
      caso (fallo a mitad de migración), migración exactamente una vez en el caso feliz.
      → REQ-5,6

Fuera de estas tasks (explícito, no bloquea GH-71 como spec): cualquier cambio a
`Package.swift`, `SSHKit`/`TerminalUI`/`RDPBridge`/`GCPClient`/`SFTPKit` (su API y
lógica interna no cambian, solo se instancian una vez por `ProfileSession` en vez de
una vez por `AppDelegate`); borrado efectivo de las ubicaciones legadas tras una
migración exitosa (REQ-MT-5 solo exige dejar de leerlas, el borrado es limpieza
posterior); renombrar/editar el nombre de un perfil desde la UI (CRUD básico de
`ProfileDescriptor.displayName`, trivial una vez exista T-MT-1, no bloquea el diseño).

Secuencia: T-MT-1 → T-MT-2 → T-MT-3 → (T-MT-4 ∥ T-MT-7) → T-MT-5 → T-MT-6.
T-MT-7 (migración) es paralelizable con T-MT-4 (coordinador) una vez T-MT-1/2 están
listos: ambos consumen `ProfileStore` pero no dependen entre sí.
