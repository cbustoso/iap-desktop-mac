# Spec Multi-tenant — design

Ref: requirements.md · Código base leído (sin modificar): `Sources/AuthKit/CredentialFacade.swift`,
`Sources/AuthKit/KeychainStore.swift`, `Sources/AuthKit/ClientIDStore.swift`,
`Sources/App/App.swift` (`AppDelegate.credentialFacade`/`knownProjectIDs`),
`Sources/SettingsStore/*`, `Sources/SSHKit/HostKeys/HostKeyVerifier.swift`
(`KeychainHostKeyStore`), `specs/settings/design.md` (patrón `service`/`suiteName`
namespaced por nivel).

## Decisión arquitectónica: un `ProfileSession` por perfil, no un selector dentro de
## una sesión compartida

Hoy `AppDelegate` es, en los hechos, un único `ProfileSession` implícito: una
`CredentialFacade`, un `GCPClient`/`ProjectWorkspace`, un `TerminalTabManager`, un
diccionario `sshSessions`, una ventana `ExplorerWindowController`. REQ-MT-4 exige que
cambiar de perfil NO rompa las conexiones del perfil anterior; la única forma de
garantizar eso sin reescribir toda la capa de sesión es que **cada perfil tenga su
propio grafo de objetos independiente**, en vez de intentar multiplexar varios perfiles
dentro de un único `TerminalTabManager`/`sshSessions` compartido (que es exactamente el
diseño que generaría fugas y colisiones entre perfiles).

```
ProfileCoordinator (nuevo, en Sources/App — orquesta N perfiles)
  ├── ProfileStore (nuevo, en AuthKit — índice de metadata no sensible, UserDefaults)
  └── [profileID: ProfileSession]   (uno por perfil con ventana abierta; perfiles sin
                                      ventana abierta solo existen en ProfileStore)

ProfileSession (nuevo, en Sources/App — ex-contenido de AppDelegate, con alcance de perfil)
  ├── CredentialFacade              (namespaced: KeychainStore(service: "...profile.<id>"))
  ├── ClientIDStore                 (namespaced: UserDefaults(suiteName: "...profile.<id>"))
  ├── GCPClient(tokenProvider:)     (uno por perfil, nunca compartido)
  ├── ProjectWorkspace(client:)     (sus knownProjectIDs namespaced)
  ├── ExplorerWindowController      (una ventana por ProfileSession)
  ├── TerminalTabManager            (sus pestañas SSH, ya existente, sin cambios internos)
  ├── SftpBrowsers                  (sus pestañas Files, ya existente, sin cambios internos)
  ├── RdpConnectFlow                (sus sesiones RDP, ya existente, sin cambios internos)
  └── sshSessions: [String: SshSession]   (igual que hoy, pero con alcance de perfil)
```

- Los tipos internos de sesión (`TerminalTabManager`, `SftpBrowsers`, `RdpConnectFlow`,
  `SshSession`, `GCPClient`, `ProjectWorkspace`) NO cambian su API ni su lógica interna:
  esta spec no modifica `Sources/SSHKit`/`Sources/TerminalUI`/`Sources/RDPBridge`
  (fuera de alcance, ver "Fuera de alcance" en `tasks.md`). El cambio es puramente de
  **composición**: en vez de que `AppDelegate` las posea directamente (una sola vez),
  las posee un `ProfileSession` por perfil, y `AppDelegate`/`ProfileCoordinator` posee
  N `ProfileSession`.
- Una ventana del Explorer SHALL seguir mostrando un único perfil (REQ-MT-2): no hay un
  "selector de perfil dentro de la ventana que recarga su contenido", sino "elegir qué
  ventana (perfil) está al frente, o crear una nueva". Esto es deliberado: es la forma
  más simple de cumplir REQ-MT-4 con el código existente, y es el patrón ya familiar de
  "perfiles = ventanas separadas" (análogo a perfiles de navegador en ventanas
  independientes, no pestañas de un mismo contexto).

## `ProfileStore` (nuevo tipo, `AuthKit`)

```swift
public struct ProfileID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String   // UUID string; `ProfileID.legacyDefault` es una constante fija
    public static let legacyDefault = ProfileID(rawValue: "legacy-default-profile")!
}

public struct ProfileDescriptor: Codable, Sendable, Equatable {
    public let id: ProfileID
    public var displayName: String        // editable por el usuario; default = email/"Perfil sin nombre"
    public var issuer: OidcIssuer?         // nil mientras no haya login completado
    public var redactedAccount: String?    // dominio del email o identidad workforce redactada (nunca el email completo)
    public var lastUsedAt: Date?
}

/// Índice de perfiles: solo metadata no sensible (REQ-MT-6), nunca tokens.
/// Persistido en UserDefaults bajo una clave propia, no namespaced por perfil
/// (es, por construcción, el único estado deliberadamente compartido entre perfiles).
public struct ProfileStore: Sendable {
    public static let defaultsKey = "profiles.index"   // UserDefaults.standard

    public init(defaults: UserDefaults = .standard) { ... }

    public func list() -> [ProfileDescriptor]
    public func upsert(_ descriptor: ProfileDescriptor) throws
    public func remove(_ id: ProfileID) throws
    /// Namespacing helpers reutilizados por `ProfileSession` (REQ-MT-3):
    public static func keychainService(for id: ProfileID, suffix: String) -> String {
        "com.iap-mac.\(suffix).profile.\(id.rawValue)"
    }
    public static func userDefaultsSuite(for id: ProfileID, component: String) -> String {
        "com.iapdesktop.mac.settings.profile.\(id.rawValue).\(component)"
    }
}
```

- `keychainService(for:suffix:)` cubre tanto `auth` (`CredentialFacade`/`KeychainStore`)
  como `settings.secure` (`KeychainSettingsStore`) y `ssh.known-hosts`
  (`KeychainHostKeyStore`) con el mismo esquema de nombre, reusando el patrón ya
  presente en `Sources/App/RdpConnect.swift`/`SettingsPanelDataSource.swift`
  (`"com.iapdesktop.mac.settings.secure.\(component)"`), solo añadiendo el segmento
  `profile.<id>`.
- `ProfileDescriptor` SHALL NOT incluir el email completo en claro de forma persistida
  más allá de lo necesario para mostrarlo en el selector (REQ-MT-2 exige mostrarlo); se
  acepta guardar el email completo en `redactedAccount` para issuer Gaia (es lo que ya
  se muestra hoy en `showAccount(email:)`/`StatusBarView`, no es un dato nuevo expuesto)
  pero el campo se nombra `redactedAccount` porque para issuer STS SHALL contener la
  representación ya redactada de `WorkforceIdentity`, nunca el `principal://` crudo.

## `ProfileSession` (nuevo tipo, `Sources/App`)

```swift
@MainActor
final class ProfileSession {
    let id: ProfileID
    let credentialFacade: CredentialFacade      // KeychainStore(service: ProfileStore.keychainService(for: id, suffix: "auth"))
    let clientIDStore: ClientIDStore            // UserDefaults(suiteName: ProfileStore.userDefaultsSuite(for: id, component: "oauth"))
    lazy var workspace: ProjectWorkspace = ...  // GCPClient(tokenProvider: accessToken) propio
    lazy var vmClient: GCPClient = ...
    var windowController: ExplorerWindowController?
    var terminalTabs: TerminalTabManager?
    var sftpBrowsers: SftpBrowsers?
    var sshSessions: [String: SshSession] = [:]
    var knownProjectIDs: [String] {
        get { UserDefaults(suiteName: ProfileStore.userDefaultsSuite(for: id, component: "explorer"))!
            .stringArray(forKey: "knownProjectIDs") ?? [] }
        set { ... }
    }

    func openWindow() { ... }     // crea ExplorerWindowController + wiring (igual que AppDelegate hoy)
    func closeWindow() async { ... }  // reutiliza specs/ssh-close/ para limpiar sesiones de ESTE perfil
}
```

- Toda la lógica de "wiring" que hoy vive en `AppDelegate` (`wireSshConnect`,
  `wireRdpConnect`, `wireSftpBrowse`, el cálculo de `accessToken`) SHALL moverse,
  conceptualmente, a `ProfileSession` (es la unidad que antes era "la app entera" y
  ahora es "un perfil"); `AppDelegate` pasa a ser más fino: crea/destruye
  `ProfileSession`s a través de `ProfileCoordinator`.
- `credentialFacade`/`clientIDStore` namespaced garantizan REQ-MT-3 a nivel de
  autenticación; `knownProjectIDs` namespaced garantiza REQ-MT-3 a nivel de tenants;
  `GCPClient`/`workspace` por instancia garantizan REQ-MT-4 (ningún interceptor
  compartido entre perfiles).

## `ProfileCoordinator` (nuevo tipo, `Sources/App`, sustituye parte de `AppDelegate`)

```swift
@MainActor
final class ProfileCoordinator {
    private let store: ProfileStore
    private var sessions: [ProfileID: ProfileSession] = [:]   // solo perfiles con ventana abierta

    func activate(_ id: ProfileID) {
        if let existing = sessions[id] { existing.windowController?.window?.makeKeyAndOrderFront(nil); return }
        let session = ProfileSession(id: id, descriptor: store.list().first { $0.id == id })
        sessions[id] = session
        session.openWindow()
    }

    func createProfile() -> ProfileID { ... }   // genera UUID, upsert en store, activate()
    func removeProfile(_ id: ProfileID) async throws {
        if let session = sessions[id] { await session.closeWindow(); sessions[id] = nil }
        try session.credentialFacade.revoke-y-borra-keychain-namespaced  // ver tasks.md T-MT-2
        try store.remove(id)
    }
    func windowDidClose(for id: ProfileID) { sessions[id] = nil }  // libera el ProfileSession
}
```

- `windowDidClose` (vía `NSWindowDelegate.windowWillClose`, patrón ya usado por
  `EventLogWindowController`/`SerialOutputWindowController`) libera el `ProfileSession`
  de memoria una vez su ventana se cierra Y sus sesiones terminaron de limpiarse
  (reutilizando `specs/ssh-close/` REQ-CLOSE-5, ahora con alcance de un solo perfil en
  vez de "toda la app").
- `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` (hoy `true` sin
  condiciones) pasa a evaluar "¿quedan `ProfileSession`s con ventana abierta?" — ya es
  equivalente, porque cada perfil es una ventana, así que no cambia el valor devuelto,
  solo lo que cuenta como "última ventana" (ahora N ventanas de N perfiles en vez de 1).

## Selector de perfiles (UI, menú `Profiles` nuevo en la barra de menú)

- Nuevo submenú `Profiles` (junto a `File`/`Session`/`View` en `Sources/App/App.swift`):
  lista dinámica de `ProfileStore.list()` (un `NSMenuItem` por perfil, acción
  `ProfileCoordinator.activate(_:)`), más `Add profile…` (crea + abre Sign In) y, dentro
  de cada ítem o en un submenú secundario, `Remove profile…` con confirmación
  (`NSAlert`, mismo patrón que `confirm(_:for:)` de `ExplorerWindowController`).
- Cada `ExplorerWindowController` ya expone `showAccount(email:)`/`accountText`
  (`Sources/ExplorerUI/ExplorerWindowController.swift:47-53`): esta spec reutiliza ese
  mecanismo para mostrar la identidad del perfil en la status bar de su ventana, sin
  tocar `ExplorerUI` (el nombre de perfil vs email es una decisión de qué string le pasa
  `ProfileSession`, no un cambio de `ExplorerUI`).
- El selector de tenant (árbol de Project Explorer) NO cambia de implementación: cada
  `ProfileSession` tiene su propio `ExplorerViewModel`/`ProjectWorkspace`, poblado solo
  con los `knownProjectIDs` de ESE perfil — el aislamiento de tenants es automático por
  construcción (REQ-MT-2), no requiere lógica nueva de filtrado en `ExplorerUI`.

## Migración del perfil único (REQ-MT-5)

```
ProfileMigrator.migrateLegacySingleProfileIfNeeded()
  1. SI UserDefaults.standard["multitenant.migration.completed"] == true → no-op.
  2. Leer estado legado:
     - KeychainStore(service: "com.iap-mac.auth").accounts()  (puede estar vacío: app nueva)
     - UserDefaults.standard.stringArray("knownProjectIDs") ?? []
     - UserDefaults.standard.string("oauth.clientID")  (override, opcional)
  3. SI no hay nada que migrar (sin accounts, sin knownProjectIDs, sin override) →
     marcar completado igualmente (perfil legacyDefault queda vacío, "pendiente de login"
     — REQ-MT-1) y terminar: no hay riesgo de pérdida de datos.
  4. Copiar cada OfflineCredential al KeychainStore namespaced de `.legacyDefault`.
  5. Copiar knownProjectIDs al UserDefaults namespaced de `.legacyDefault`.
  6. Copiar el override de client ID (si existía) al UserDefaults namespaced.
  7. Verificar: releer todo lo copiado desde las ubicaciones namespaced y comparar.
  8. SI la verificación OK → upsert ProfileDescriptor(.legacyDefault, …) en ProfileStore
     → marcar "multitenant.migration.completed" = true.
  9. SI cualquier paso falla → NO marcar completado, NO borrar nada legado, loguear
     (sin datos sensibles) y dejar que la app siga funcionando en modo "perfil único
     implícito": `ProfileCoordinator` detecta que no hay migración completada y trata
     `.legacyDefault` como un perfil siempre existente que lee directamente de las
     ubicaciones legadas (fallback, no bloquea el uso de la app).
```

- Este migrador SHALL ejecutarse una sola vez al arrancar `AppDelegate`, antes de
  `ProfileCoordinator.activate(.legacyDefault)` (que sustituye el `credentialFacade =
  CredentialFacade()` + `restoreOffline` que hoy hace `AppDelegate` directamente).
- El borrado de las ubicaciones legadas (`KeychainStore(service: "com.iap-mac.auth")`
  global, `UserDefaults.standard["knownProjectIDs"]`) es explícitamente una limpieza
  POSTERIOR y opcional (REQ-MT-5): esta spec no la exige para considerar la migración
  "hecha", solo exige dejar de LEERLAS como fuente de verdad una vez migradas y
  verificadas.

## Errores tipados
`ProfileError.{notFound(ProfileID), migrationVerificationFailed, keychainNamespaceFailure(OSStatus), cannotRemoveActiveProfileWindow}`
(el último para rechazar un borrado si la ventana sigue abierta sin confirmar el cierre
primero — UX, no bloqueante de datos).

## Fuera de alcance de esta spec (ver tasks.md)
Implementación real de `ProfileSession`/`ProfileCoordinator`/`ProfileStore`/
`ProfileMigrator`, el menú `Profiles`, y cualquier cambio a `Package.swift`,
`SSHKit`/`TerminalUI`/`RDPBridge`/`GCPClient` (sin cambios: solo se instancian una vez
por perfil en vez de una vez por app, su código interno no cambia). Esta tarea es
spec-only (GH-71 pide "idear el diseño").
