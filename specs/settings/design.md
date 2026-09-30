# Spec Settings — design (`SettingsStore`)

Ref: requirements.md · Origen C#: `Settings/{ISettingsStore,MergedSettingsStore,
RegistrySettingsStore,DictionarySettingsStore,SettingBase}.cs`,
`Settings/Collection/{GroupPolicyAwareRepository,RepositoryBase,PersistentSettingsCollection}.cs`,
`Extensions.Session/Settings/{ConnectionSettings,ConnectionSettingsRepository,
SshSettings,TerminalSettings}.cs`.

## Arquitectura (`SettingsStore`)

```
Setting<T> (key, displayName, description, category, defaultValue, validate)
  ↑ leído/escrito por
ISettingsStore  ──┬── UserDefaultsSettingsStore (no sensible, por dominio/nivel)
                  ├── KeychainSettingsStore     (sensible: passwords)
                  └── MDMSettingsStore          (solo lectura, managed preferences)
        ↓ compuestos por
MergedSettingsStore(stores: [...], behavior: .overlay | .policy)
        ↓ orquestado por
SettingsRepository (Universo → Proyecto → Zona → Instancia, layout project/zone-/vm-)
        ↓ expone
ConnectionSettings / SshSettings / TerminalSettings (ISettingsCollection)
```

- `SettingsStore` (target SPM) es una librería pura (sin UI): `ExplorerUI`/`App` la
  consumen para leer/escribir settings efectivos y para pintar la UI de propiedades
  (`PropertiesView`, ver `Sources/ExplorerUI/PropertiesView.swift`) marcando los campos
  `isReadOnly` cuando hay política.

## `Setting<T>` y `ISettingsStore`

- `Setting<T>`: struct `Sendable` con `key: String`, `displayName: String?`,
  `description: String?`, `category: String?`, `value: T`, `defaultValue: T`,
  `isSpecified: Bool`, `isReadOnly: Bool`, `isDirty: Bool` (paridad `ISetting<T>`);
  `isDefault` computado (`value == defaultValue`); `reset()` restaura `defaultValue`.
- `protocol SettingsStore`: `read<T>(key:displayName:description:category:defaultValue:
  validate:) -> Setting<T>`, `write(_ setting: any AnySetting)`, `clear() throws`.
- `AnySetting` (protocolo interno, paridad `IAnySetting`): permite a `write` operar sobre
  el valor tipado sin genéricos explícitos en el call site (conversión de tipo runtime
  controlada, cero `Any` sin chequeo).

## Fuentes de almacenamiento

- `UserDefaultsSettingsStore`: envuelve `UserDefaults(suiteName:)` por nivel (un dominio
  por combinación app+nivel, o claves prefijadas dentro de un dominio único — decisión de
  implementación en T-SET-2, no bloquea esta spec); serializa enums congelados por
  `rawValue` (String o Int estable, nunca por posición de `CaseIterable`).
- `KeychainSettingsStore`: `kSecClassGenericPassword`, servicio
  `com.iap-mac.settings.secure`, cuenta = `key` compuesta con el nivel (paridad
  `SecureString` → nunca serializa a `UserDefaults`); implementa el mismo protocolo
  `SettingsStore` para que `MergedSettingsStore` no necesite distinguir el origen.
- `MDMSettingsStore`: lectura de `CFPreferences`/managed preferences
  (`com.apple.ManagedClient.preferences`, dominio propio de la app); `write`/`clear`
  SHALL lanzar `SettingsError.readOnlyStore` (nunca escribe políticas).

## `MergedSettingsStore`

- `MergeBehavior { case overlay, policy }` (paridad `MergedSettingsStore.MergeBehavior`).
- `merge(lesser:overlay:) -> Setting<T>`:
  - `.policy`: si `overlay.isSpecified && overlay.isCurrentValueValid` → devuelve
    `lesser` con `value = overlay.value`, `isReadOnly = true`, `isSpecified = true`;
    si no, devuelve `lesser` sin cambios (política no aplica).
  - `.overlay`: si `overlay.isSpecified` → `lesser` con `value = overlay.value`,
    `defaultValue = lesser.value` (nuevo default, paridad "el valor del store inferior
    pasa a ser el nuevo default"), `isSpecified = true`; si no →
    `defaultValue = lesser.value` también pero `isSpecified` se conserva del `lesser`.
- `read<T>` aplica `merge` en cascada sobre `stores` (orden: menos → más importante).
- `write` en `.policy` escribe siempre en `stores.first` (nunca en la capa de política);
  en `.overlay` escribe en `stores.last`.
- `clear()` SHALL lanzar `SettingsError.mergedStoreNotClearable` (paridad
  `InvalidOperationException` de `MergedSettingsStore.Clear`).

## Herencia Universo → Proyecto → Zona → Instancia

- `SettingsRepository` (actor, único punto de entrada de `App`/`ExplorerUI`):
  - `universeStore() -> some SettingsStore` — `MergedSettingsStore([user, mdm], .policy)`
    si hay política MDM activa, o directo `UserDefaultsSettingsStore` si no.
  - `projectStore(_ project: ProjectLocator) -> some SettingsStore` —
    `MergedSettingsStore([universeStore(), projectLevelStore(project)], .overlay)`.
  - `zoneStore(_ zone: ZoneLocator) -> some SettingsStore` —
    `MergedSettingsStore([projectStore(zone.project), zoneLevelStore(zone)], .overlay)`.
  - `instanceStore(_ instance: InstanceLocator) -> some SettingsStore` —
    `MergedSettingsStore([zoneStore(instance.zone), instanceLevelStore(instance)],
    .overlay)`.
  - `ephemeralOverlay(_ base: some SettingsStore, urlParameters: [String: String]) ->
    some SettingsStore` — para parámetros de una URL `iap-rdp://…`/`iap-ssh://…` sin
    persistir (paridad `IapRdpUrlSettingsStore` + `MergedSettingsStore` ad hoc).
- `ProjectLocator`/`ZoneLocator`/`InstanceLocator`: reutilizan los identificadores ya
  presentes en `ExplorerUI.ProjectInfo/ZoneInfo/InstanceInfo` (mismo `project`, `zone`,
  `name`) para no duplicar modelos de dominio.

## Layout de persistencia

```
UserDefaults / Keychain (dominio app)
  └ universe                       → Setting<T> nivel Universo
  └ project.<project-id>           → Setting<T> nivel Proyecto
  └ project.<project-id>.zone-<zone-id>      → Setting<T> nivel Zona
  └ project.<project-id>.vm-<instance-name>  → Setting<T> nivel Instancia
```

- Claves compuestas por concatenación estable (`.` como separador, sin caracteres del
  propio identificador de proyecto/zona/instancia que puedan colisionar — normalizar con
  el mismo id determinista que usa `ExplorerNode.id`).
- `KeychainSettingsStore` usa la misma jerarquía de claves como `account` en
  `kSecClassGenericPassword`, con `service` fijo por tipo de secreto (RDP password vs SSH
  password) para evitar colisiones entre niveles.

## Esquema de settings (~40, enums congelados)

- `ConnectionSettings` (RDP ~24 + SSH ~6 + App ~2): mismas claves/categorías que el
  original (`RdpUsername`, `RdpPassword`, `RdpDomain`, `RdpConnectionBar`,
  `RdpAuthenticationLevel`, `RdpColorDepth`, `RdpAudioPlayback`, `RdpAudioInput`,
  `RdpAutomaticLogon`, `RdpNetworkLevelAuthentication`, `RdpConnectionTimeout`, `RdpPort`,
  `RdpTransport`, `RdpRedirect{Clipboard,Printer,SmartCard,Port,Drive,Device,WebAuthn}`,
  `RdpHookWindowsKeys`, `RdpRestrictedAdminMode`, `RdpSessionType`, `RdpDpiScaling`,
  `RdpDesktopSize`; `SshPort`, `SshTransport`, `SshPublicKeyAuthentication`,
  `SshUsername`, `SshPassword`, `SshConnectionTimeout`; `AppUsername`,
  `AppNetworkLevelAuthentication`).
- `SshPlatformSettings` (~5, paridad `SshSettingsRepository`): `publicKeyValidity`,
  `publicKeyType` (enum `SshKeyType`, ver `specs/ssh/design.md`), `usePersistentKey`,
  `enableLocalePropagation`, `enableFileAccess` (gate de SFTP, `specs/sftp/` futuro).
- `TerminalSettings` (~11): `isCopyPasteUsingCtrlCCtrlVEnabled`,
  `isCopyPasteUsingShiftInsertCtrlInsertEnabled`, `isQuoteConversionOnPasteEnabled`,
  `isBracketedPasteEnabled`, `isScrollingUsingCtrlHomeEndEnabled`,
  `isScrollingUsingCtrlPageUpDownEnabled`, `fontFamily`, `fontSize`,
  `foregroundColor`/`backgroundColor` (representación `Sendable`, no `NSColor` directo —
  ARGB `UInt32` como el original), `caretStyle` (enum, paridad `VirtualTerminal.CaretStyle`).
- Cada enum congelado vive en su target de dominio correspondiente
  (`RdpColorDepth`/`RdpTransport`… en `RDPBridge`, `SshKeyType`/`SshTransport` en
  `SSHKit`, `CaretStyle` en `TerminalUI`) e implementa `RawRepresentable` con `rawValue`
  estable para persistencia; `SettingsStore` solo depende de `RawRepresentable &
  Sendable`, nunca de los módulos de protocolo (evita ciclos de dependencia en
  `Package.swift`).
- `SettingsSchemaVersion` (enum congelado en `SettingsStore`, paridad
  `UserProfile.SchemaVersion`): permite condicionar el *default* de un setting nuevo
  (ejemplo: `SshKeyType` por defecto RSA-3072 en esquemas antiguos, ECDSA P-384 en
  esquemas nuevos) sin migrar perfiles existentes.

## Errores tipados
`SettingsError.{mergedStoreNotClearable, readOnlyStore, unknownEnumValue(key:raw:),
keychainFailure(OSStatus), invalidValue(key:), mdmUnavailable}`.

## Tests primero
Portar la matriz de `MergedSettingsStore` (overlay vs policy, especificado/no
especificado, válido/inválido) como tests unitarios antes de implementar
`SettingsRepository`; luego tests de herencia de 4 niveles con valores intercalados
(paridad conceptual con `TestRdpWithGroupPolicies.cs`).
