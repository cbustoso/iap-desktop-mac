# Spec Settings — requirements (EARS)

Ref: `docs/feature-parity.md` §8 (settings con herencia) · Linear CBU-34.
Origen C#: `Google.Solutions.Settings/*` (`ISettingsStore`, `MergedSettingsStore`,
`RegistrySettingsStore`, `DictionarySettingsStore`, `Collection/GroupPolicyAwareRepository`)
y `Google.Solutions.IapDesktop.Extensions.Session/Settings/*`
(`ConnectionSettings`, `ConnectionSettingsRepository`, `SshSettings`, `TerminalSettings`).

## REQ-SET-1 — `MergedSettingsStore`: overlay y policy
- El sistema SHALL implementar un `MergedSettingsStore` que combine N `ISettingsStore` en
  orden de importancia creciente (el último gana), con dos comportamientos de fusión
  (paridad `MergeBehavior`):
  - **Overlay**: si el store superior tiene el valor especificado, lo usa como valor
    efectivo y el valor del store inferior pasa a ser el nuevo *default*; si no lo
    especifica, el valor/estado `isDefault` del inferior se propaga sin cambios.
  - **Policy**: si el store de política tiene un valor especificado y válido, ese valor
    SHALL ser el efectivo y el setting SHALL quedar `isReadOnly = true`; si no está
    especificado o es inválido, se ignora y el valor inferior se mantiene editable.
- El sistema SHALL lanzar/rechazar `write()` sobre un `MergedSettingsStore` en modo
  Policy: SHALL escribir siempre en el store menos importante (nunca en la capa de
  política); en modo Overlay SHALL escribir en el store más importante.
- `clear()` sobre un `MergedSettingsStore` SHALL fallar (operación no soportada, paridad
  con `MergedSettingsStore.Clear` → `InvalidOperationException`).

## REQ-SET-2 — Fuentes de almacenamiento: UserDefaults, Keychain, MDM
- El sistema SHALL exponer al menos tres implementaciones de `ISettingsStore`
  (equivalentes a `RegistrySettingsStore`/`DictionarySettingsStore`):
  - `UserDefaultsSettingsStore`: valores no sensibles del usuario (`UserDefaults` con
    dominio/suite propio por nivel de jerarquía, ver REQ-SET-3).
  - `KeychainSettingsStore`: valores sensibles (`SecureString` en el original →
    contraseñas RDP/SSH) persistidos en Keychain (`kSecClassGenericPassword`), nunca en
    `UserDefaults` ni en logs.
  - `MDMSettingsStore` (solo lectura): valores de política gestionados por MDM (paridad
    `machinePolicyKey`/`userPolicyKey` de Group Policy), leídos de
    `com.apple.ManagedClient.preferences` o el mecanismo de configuración administrada
    equivalente en macOS.
- WHEN existe una política MDM para un setting THEN el sistema SHALL componer
  `MergedSettingsStore(stores: [user, mdm], behavior: .policy)` (paridad
  `GroupPolicyAwareRepository`: política de máquina > política de usuario > valor local).
- El sistema SHALL exponer `isPolicyPresent` (hay más de un store activo) para que la UI
  de Settings deshabilite el control y muestre el origen ("gestionado por tu
  organización").

## REQ-SET-3 — Herencia Universo → Proyecto → Zona → Instancia
- El sistema SHALL resolver settings efectivos en 4 niveles, cada uno como overlay del
  anterior (paridad `ConnectionSettingsRepository.Create{Universe,Project,Zone,Instance}
  SettingsStore`):
  1. **Universo** (`UniverseLocator.cloud`, ámbito global de la app).
  2. **Proyecto** (`ProjectLocator`, overlay sobre Universo).
  3. **Zona** (`ZoneLocator`, overlay sobre Proyecto).
  4. **Instancia** (`InstanceLocator`, overlay sobre Zona).
- El sistema SHALL construir el store de cada nivel como
  `MergedSettingsStore(behavior: .overlay)` de [nivel(es) padre, store propio del nivel],
  de forma que leer settings de Instancia devuelva el valor más específico definido,
  cayendo en cascada hasta Universo si ningún nivel intermedio lo especifica.
- El sistema SHALL permitir componer una capa adicional efímera (paridad
  `IapRdpUrlSettingsStore`: parámetros de una URL `iap-rdp://` superpuestos sobre los
  settings guardados de la instancia) sin persistirla.
- Escribir settings en un nivel SHALL afectar solo a ese nivel (nunca "sube" a padres ni
  "baja" a hijos); solo el valor `IsDirty` del nivel objetivo se persiste.

## REQ-SET-4 — Layout de almacenamiento (`project/zone-/vm-`)
- El sistema SHALL organizar las claves de persistencia con el mismo layout plano del
  original (adaptado a `UserDefaults`/Keychain, sin registro de Windows):
  ```
  [app-domain]
     + [project-id]            → settings de Proyecto
       + zone-[zone-id]        → settings de Zona (prefijo "zone-")
       + vm-[instance-name]    → settings de Instancia (prefijo "vm-")
  ```
- Las claves individuales dentro de cada nivel SHALL ser estables y ASCII (nombres de
  setting, no localizados), para permitir migraciones futuras sin romper compatibilidad.
- El sistema SHALL derivar el identificador de Zona/Instancia de forma determinista a
  partir de `ProjectInfo`/`ZoneInfo`/`InstanceInfo` (ver `Sources/ExplorerUI/Models.swift`),
  coherente con los IDs usados por `ExplorerNode` (`project:<id>`, `zone:<id>`,
  `instance:<project>/<zone>/<name>`).

## REQ-SET-5 — Esquema de ~40 settings con enums congelados
- El sistema SHALL definir un esquema fijo de settings agrupados por categoría (paridad
  `ConnectionSettings` + `SshSettingsRepository` + `TerminalSettings`, ~40 propiedades
  en total):
  - **RDP** (~24): credenciales de Windows (username/password/domain), conexión
    (transporte, puerto, timeout), pantalla (color depth, resolución, DPI scaling, barra
    de conexión), recursos redirigidos (audio, clipboard, impresoras, smart cards,
    puertos, unidades, dispositivos, WebAuthn, teclas Windows), seguridad (NLA, nivel de
    autenticación, logon automático, Restricted Admin, tipo de sesión).
  - **SSH** (~11): transporte, puerto, timeout de conexión, autenticación por llave
    pública, usuario, password, validez de llave pública, tipo de llave pública,
    persistencia de la llave de firma, propagación de locale, acceso a archivos (SFTP).
  - **Terminal** (~11): copy/paste (Ctrl+C/V, Shift+Insert, conversión de comillas,
    paste con corchetes), scroll (Ctrl+Home/End, Ctrl+PageUp/Down), fuente
    (familia, tamaño), colores (foreground/background ARGB), estilo de cursor.
- Cada setting SHALL tener: clave estable, nombre para mostrar, descripción, categoría,
  valor por defecto y (si aplica) validador — paridad con la firma
  `Read<T>(name, displayName, description, category, defaultValue, validate)`.
- Los settings de tipo enumerado (transporte, color depth, redirecciones RDP, tipo de
  llave SSH, estilo de cursor, etc.) SHALL usar un `enum` Swift **congelado** (sin caso
  `default`/`@unknown default` implícito que oculte valores no migrados): añadir un caso
  nuevo requiere versión de esquema explícita (ver REQ-SET-6), nunca un valor "silencioso"
  no manejado.
- El sistema SHALL validar rangos numéricos (timeouts, puertos, validez de llave) con
  predicados equivalentes a `Predicate.InRange` del original.

## REQ-SET-6 — Versionado de esquema y migración
- El sistema SHALL registrar una `SchemaVersion` (paridad `UserProfile.SchemaVersion`)
  que permita cambiar el *default* de un setting para perfiles nuevos sin afectar a
  perfiles existentes (ejemplo real portado: tipo de llave SSH por defecto cambió de
  RSA-3072 a ECDSA P-384 a partir de una versión de esquema).
- WHEN se lee un valor persistido que no corresponde a ningún caso del enum congelado
  vigente (esquema antiguo con un caso retirado) THEN el sistema SHALL fallar tipado
  (`SettingsError.unknownEnumValue`) en lugar de mapear a un valor por defecto silencioso.

## REQ-SET-7 — Seguridad y observabilidad
- El sistema SHALL NOT persistir contraseñas (RDP/SSH) fuera de Keychain, ni loguear su
  valor (paridad `SecureString`/`GetClearTextValue` — acceso explícito, nunca implícito
  en logs/`description`).
- El sistema SHALL redactar en OSLog cualquier valor marcado como sensible al volcar el
  estado de un `ISettingsCollection` para diagnóstico.

## Trazabilidad
REQ-SET-1 → T-SET-1 · REQ-SET-2 → T-SET-2,3 · REQ-SET-3 → T-SET-4 · REQ-SET-4 → T-SET-4,5 ·
REQ-SET-5 → T-SET-6,7,8 · REQ-SET-6 → T-SET-9 · REQ-SET-7 → T-SET-2,10.
