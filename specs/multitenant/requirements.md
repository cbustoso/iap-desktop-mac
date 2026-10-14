# Spec Multi-tenant — requirements (EARS)

Ref: `specs/auth/requirements.md` (REQ-AUTH-1..6) y `specs/auth/design.md` (base de
`CredentialFacade`/`KeychainStore`/`ClientIDStore`) · `specs/settings/design.md`
(jerarquía `UserDefaultsSettingsStore`/`KeychainSettingsStore` por nivel, patrón de
`suiteName`/`service` namespaced que esta spec extiende con un nivel nuevo) ·
Linear GH-71 (pedida por el dueño).

Código leído como base (solo lectura, sin modificar): `Sources/AuthKit/CredentialFacade.swift`
(actor único, `splice`/`revoke`/`storeRefreshed`, `AsyncStream` `Reauthorized`),
`Sources/AuthKit/KeychainStore.swift` (`service: String` inyectable, cuenta
`<issuer>:<email>`), `Sources/AuthKit/ClientIDStore.swift` (resolución
`UserDefaults` → `Info.plist` → entorno), `Sources/App/App.swift` (`credentialFacade`
como única instancia global del `AppDelegate`, `knownProjectIDs` en
`UserDefaults.standard` sin namespacing).

## Terminología de esta spec
- **Perfil**: contenedor independiente de identidad = una cuenta Google/Workforce
  (`OfflineCredential`) + su client OAuth (anulación opcional vía `ClientIDStore`) + su
  lista de proyectos conocidos (tenants) + sus settings/Keychain propios. Identificado
  por un `profileID` opaco (UUID), NO derivado del email (dos perfiles pueden compartir
  el mismo email de Google con client OAuth distintos — p. ej. acceso interno vs
  cross-org — y una identidad workforce no tiene email real, ver `WorkforceIdentity`).
- **Tenant**: un proyecto GCP (`project-id`) dentro de un perfil; reutiliza el concepto
  ya existente de `knownProjectIDs` (`Sources/App/App.swift:225-227`), ahora con alcance
  por perfil en vez de global.
- **Perfil activo en una ventana**: el perfil cuyo `ProfileSession` (ver design.md)
  alimenta esa ventana del Explorer en un momento dado.

## REQ-MT-1 — Perfiles independientes (cuenta + client OAuth + proyectos)
- El sistema SHALL permitir crear múltiples perfiles, cada uno con: una cuenta
  autenticada (`OfflineCredential`, vía el flujo OAuth ya existente de REQ-AUTH-1), un
  client OAuth efectivo propio (override de `ClientIDStore` con alcance de perfil, o el
  valor por defecto embebido/entorno si el perfil no fija uno), y una lista de tenants
  (`knownProjectIDs`) propia.
- WHEN el usuario crea un perfil nuevo THEN el sistema SHALL generar un `profileID`
  (UUID) estable para toda la vida del perfil y SHALL pedir el login OAuth (REQ-AUTH-1)
  antes de considerarlo utilizable; un perfil sin cuenta autenticada SHALL mostrarse
  como "pendiente de iniciar sesión", nunca como error.
- El sistema SHALL soportar dos perfiles con la MISMA cuenta Google (mismo email) si
  usan client OAuth distintos; el sistema SHALL NOT deduplicar perfiles por email.
- WHEN el usuario elimina un perfil THEN el sistema SHALL borrar su `CredentialFacade`
  en memoria, su entrada de Keychain namespaced (REQ-MT-3), sus settings namespaced y su
  metadata del índice de perfiles (REQ-MT-2); SHALL pedir confirmación explícita antes
  de borrar (operación irreversible, pierde la sesión y el client OAuth override de ese
  perfil).

## REQ-MT-2 — Selector de perfil y de tenant
- El sistema SHALL exponer un selector de perfiles (menú o panel, análogo a un selector
  de perfiles de navegador) que liste todos los perfiles conocidos (metadata no
  sensible: `profileID`, nombre para mostrar, email/identidad redactada, issuer, fecha
  de último uso) y permita: cambiar a un perfil existente, crear uno nuevo ("Add
  profile…", reutilizando el flujo de Sign In), o eliminar uno.
- WHEN el usuario selecciona un perfil ya abierto (con ventana existente) THEN el
  sistema SHALL llevar esa ventana al frente SIN crear una `ProfileSession` nueva ni
  tocar su estado (sesiones SSH/RDP/SFTP, túneles, pestañas abiertas intactas).
- WHEN el usuario selecciona un perfil sin ventana abierta THEN el sistema SHALL crear
  una `ProfileSession` nueva (REQ-MT-4) y su ventana del Explorer, cargando los tenants
  conocidos de ese perfil.
- Dentro de la ventana de un perfil, el selector de tenant (proyecto) SHALL ser el árbol
  de Project Explorer ya existente, con alcance restringido a los `knownProjectIDs` de
  ESE perfil (REQ-MT-3): un perfil SHALL NOT ver ni autodescubrir proyectos añadidos por
  otro perfil, aunque ambos usen la misma cuenta Google subyacente.
- El sistema SHALL mostrar, en cada ventana del Explorer, de qué perfil es (nombre o
  cuenta, reutilizando `showAccount(email:)` ya existente en `ExplorerWindowController`
  con el matiz de que ahora identifica también el perfil cuando hay más de uno abierto).

## REQ-MT-3 — Aislamiento de tokens/sesiones/Keychain por perfil
- Cada perfil SHALL tener su propio `CredentialFacade` (una instancia de actor por
  perfil, no la instancia única global actual de `AppDelegate`): su `generation`, su
  `AsyncStream` de `Reauthorized`, su `accessToken`/`accessTokenExpiry` en memoria SHALL
  NOT compartirse entre perfiles bajo ninguna circunstancia.
- El `KeychainStore` de cada perfil SHALL usar un `service` namespaced por `profileID`
  (p. ej. `com.iap-mac.auth.profile.<profileID>`, extendiendo el parámetro `service`
  que `KeychainStore` ya acepta — `Sources/AuthKit/KeychainStore.swift:9`), de forma que
  `accounts()` de un perfil SHALL NOT listar ni leer entradas de otro perfil, y borrar
  todas las entradas de un perfil (al eliminarlo, REQ-MT-1) SHALL NOT afectar al
  Keychain de los demás.
- El `ClientIDStore` de cada perfil SHALL resolver su override desde un
  `UserDefaults(suiteName:)` namespaced por perfil (no `.standard` global), de forma que
  dos perfiles puedan tener client OAuth distintos simultáneamente sin pisarse; el
  default embebido (`Info.plist`)/entorno SHALL seguir siendo compartido como última
  rama de resolución (no tiene sentido duplicar el binario por perfil).
- Los `knownProjectIDs` (tenants) de cada perfil SHALL persistirse bajo una clave/suite
  namespaced por perfil (p. ej. `UserDefaults(suiteName: "com.iapdesktop.mac.settings.profile.<profileID>")`,
  mismo patrón de `suiteName` por componente ya usado en `specs/settings/design.md`),
  NUNCA en la clave global `knownProjectIDs` de `UserDefaults.standard` que usa hoy
  `Sources/App/App.swift:226`.
- Los almacenes de settings con alcance proyecto/zona/instancia
  (`KeychainSettingsStore`/`UserDefaultsSettingsStore`, credenciales RDP, host keys SSH
  vía `KeychainHostKeyStore`) SHALL añadir el `profileID` como primer segmento de su
  `service`/`suiteName` (p. ej. `com.iap-mac.auth.profile.<profileID>` para host keys en
  vez del `com.iapdesktop.mac.ssh.known-hosts` global de hoy), de forma que dos perfiles
  conectando a instancias con el mismo nombre (incluso en el mismo proyecto, si ambos
  tienen acceso) SHALL NOT compartir ni corromper el estado del otro (contraseñas RDP,
  huellas de host key SSH, settings efectivos).
- El sistema SHALL NOT escribir en ningún Keychain/UserDefaults compartido entre
  perfiles ningún dato que identifique la sesión de otro perfil (tokens, emails, nombres
  de proyecto); el único estado compartido entre perfiles SHALL ser la metadata no
  sensible del índice de perfiles (REQ-MT-2) y el client OAuth por defecto embebido.

## REQ-MT-4 — Cambio de perfil sin romper conexiones del otro perfil
- WHILE un perfil A tiene sesiones activas (SSH, RDP, SFTP, túneles IAP abiertos) THEN
  cambiar el foco a un perfil B (REQ-MT-2) SHALL NOT cerrar, pausar, ni degradar
  ninguna sesión de A: cada perfil SHALL correr su propio conjunto de gestores de sesión
  (`TerminalTabManager`, `SftpBrowsers`, el flujo RDP, el diccionario de `SshSession`
  activas) dentro de su `ProfileSession` (ver design.md), de forma que no exista un
  singleton compartido entre perfiles que un cambio de foco pueda tocar.
- El cambio de perfil SHALL ser una operación de UI (qué ventana está al frente / qué
  `ProfileSession` se crea o se activa), nunca una operación que reconstruya o reemplace
  el `CredentialFacade`/sesiones de un perfil ya en marcha.
- Cerrar la ventana de un perfil SHALL cerrar únicamente las sesiones de ESE perfil
  (reutilizando la limpieza ya especificada en `specs/ssh-close/`), SHALL NOT afectar a
  otros perfiles con ventana abierta.
- Revocar la sesión de un perfil (`CredentialFacade.revoke()`, REQ-AUTH-3) SHALL NOT
  emitir `Reauthorized` hacia los interceptores de `GCPClient` de otro perfil: cada
  perfil SHALL tener su propia instancia de `GCPClient`/interceptor, nunca una
  compartida (paridad con REQ-MT-3, pero a nivel de capa de red en vez de credenciales).

## REQ-MT-5 — Migración del perfil único actual
- WHEN la app arranca por primera vez tras incorporar esta funcionalidad Y existe estado
  de sesión único "legado" (entradas en el `KeychainStore` con `service` global
  `com.iap-mac.auth`, `knownProjectIDs` en `UserDefaults.standard`, override de
  `oauth.clientID` en `UserDefaults.standard`) THEN el sistema SHALL migrar ese estado a
  un perfil nuevo con un `profileID` fijo y determinista (p. ej. una constante
  `ProfileID.legacyDefault`, NO un UUID aleatorio) para que la migración sea idempotente
  si se repite por error.
- La migración SHALL copiar (no mover) los datos legados a las ubicaciones namespaced
  del perfil (REQ-MT-3) y SHALL verificar la copia con una lectura de vuelta antes de
  considerar la migración completa; solo tras verificar con éxito SHALL marcar un flag
  "migración completada" (UserDefaults, clave propia no namespaced) para no repetirla en
  arranques futuros.
- IF la migración falla en cualquier paso (Keychain, UserDefaults) THEN el sistema SHALL
  conservar el comportamiento de perfil único actual sin pérdida de datos (los datos
  legados SHALL NOT borrarse si la copia no se verificó con éxito) y SHALL registrar el
  motivo en OSLog sin datos sensibles; la app SHALL seguir siendo usable en modo
  "perfil único implícito" aunque la migración no se haya completado.
- Tras una migración exitosa, el sistema SHALL dejar de leer las ubicaciones legadas
  (`UserDefaults.standard["knownProjectIDs"]`, `KeychainStore(service: "com.iap-mac.auth")`
  global) salvo para el propio proceso de migración; el borrado efectivo de las entradas
  legadas SHALL ser una limpieza posterior opcional (no bloqueante para esta spec), para
  minimizar el riesgo de pérdida de datos si el usuario vuelve a una versión anterior
  antes de confirmar que todo funciona.
- El perfil migrado (`legacyDefault`) SHALL aparecer en el selector de perfiles
  (REQ-MT-2) con un nombre identificable (p. ej. el email de la cuenta restaurada, o
  "Perfil principal" si aún no hay sesión) desde el primer arranque tras la migración.

## REQ-MT-6 — Seguridad y observabilidad
- El sistema SHALL NOT registrar en OSLog ningún dato que permita correlacionar perfiles
  entre sí (emails, tokens, nombres de proyecto); los eventos de cambio/creación/borrado
  de perfil SHALL loguearse solo con el `profileID` opaco.
- Un fallo de Keychain/UserDefaults al operar sobre un perfil SHALL fallar de forma
  aislada (ese perfil, ese `ProfileSession`) y SHALL NOT afectar a otros perfiles en
  memoria ni al proceso completo (sin `fatalError`/crash por un perfil con estado
  corrupto).

## Trazabilidad
REQ-MT-1 → T-MT-1,2 · REQ-MT-2 → T-MT-3,4 · REQ-MT-3 → T-MT-2,5 · REQ-MT-4 → T-MT-4,6 ·
REQ-MT-5 → T-MT-7 · REQ-MT-6 → T-MT-2,5,7.
