# Guía de uso y entorno

Cómo compilar, testear, generar el `.app` y capturar snapshots de IAP Desktop
Mac, más el troubleshooting habitual del toolchain macOS/Swift.

## 1. Requisitos: CommandLineTools vs Xcode completo

- **macOS 14+**, **Swift 6** (concurrencia estricta).
- Hay dos formas de tener el toolchain instalado:
  - **CommandLineTools (CLT) sin Xcode completo** — suficiente para
    `swift build`. Para `swift test` hace falta el workaround de la
    sección 3 (el plugin de macros de `swift-testing` no siempre se
    pasa al compilador solo con CLT).
  - **Xcode 16+ completo** (`xcode-select -s /Applications/Xcode_16.app/Contents/Developer`)
    — recomendado. Con Xcode completo `swift test` funciona sin flags
    extra. El CI (`.github/workflows/ci.yml`) usa un runner con Xcode y
    no necesita el workaround.
- Verifica qué toolchain está activo con:

  ```bash
  xcode-select -p
  swift --version
  ```

## 2. Build

```bash
swift build
```

Compila todos los targets de `Package.swift` (`AuthKit`, `GCPClient`,
`TunnelKit`, `SSHKit`, `TerminalUI`, `SFTPKit`, `RDPBridge`,
`SettingsStore`, `ExplorerUI`, `App`). El binario queda en
`.build/debug/App`.

## 3. Tests (y el workaround `-Xswiftc` en CLT)

```bash
swift test
```

Con **CommandLineTools sin Xcode completo**, SwiftPM puede no pasar el
plugin de macros de `swift-testing` al compilador
(`TestingMacros plugin not found`, ver sección de troubleshooting).
Si te pasa, usa este workaround verificado:

```bash
swift test -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

Con Xcode completo instalado y seleccionado (`xcode-select -s
/Applications/Xcode_16.app/Contents/Developer`) no hace falta: `swift
test` funciona directo.

## 4. Generar y abrir `dist/IAPDesktopMac.app`

```bash
tools/make-app-bundle.sh          # debug (por defecto)
tools/make-app-bundle.sh release  # o release
open dist/IAPDesktopMac.app
```

El script compila con `swift build -c <config>` y empaqueta el binario
+ `resources/Info.plist` en `dist/IAPDesktopMac.app`. La app no está
firmada — ver Gatekeeper en troubleshooting.

## 5. Modo snapshot (`tools/snapshot.sh`)

Captura la ventana principal (outline + toolbar) a PNG en modo claro y
oscuro, sin pedir permiso de grabación de pantalla (la propia app se
renderiza a sí misma vía `NSView.cacheDisplay` y sale).

```bash
tools/snapshot.sh [dir-salida] [node-id]
# por defecto:
tools/snapshot.sh dist/snapshots "instance:demo-web/europe-west1-b/web-01"
```

Genera `dist/snapshots/explorer-light.png` y
`dist/snapshots/explorer-dark.png`. Internamente compila con `swift
build` y lanza `.build/debug/App` con las variables de entorno:

- `IAP_SNAPSHOT=<ruta.png>` — activa el modo snapshot y fija el destino.
- `IAP_SNAPSHOT_SELECT=<node id>` — preselecciona un nodo del árbol
  (p. ej. `instance:<proyecto>/<zona>/<nombre>`).
- `IAP_SNAPSHOT_APPEARANCE=light|dark` — fuerza la apariencia solo
  durante la captura (en uso normal manda el sistema).

Ver `Sources/App/App.swift` (`snapshotIfRequested`) para el detalle de
implementación.

## 6. Troubleshooting

### `TestingMacros plugin not found` (flake en CLT)

- **Síntoma**: `swift test` falla —a veces de forma intermitente, a
  veces persistente— con un error de que no encuentra el plugin de
  macros de `swift-testing` (`TestingMacros`).
- **Causa**: con solo CommandLineTools (sin Xcode completo), SwiftPM no
  siempre localiza/pasa ese plugin al compilador.
- **Solución A (recomendada)**: instalar Xcode 16+ completo y
  seleccionarlo con `xcode-select -s
  /Applications/Xcode_16.app/Contents/Developer`.
- **Solución B (workaround)**: usar el flag `-Xswiftc` de la sección 3
  para apuntar explícitamente a la `.dylib` del plugin dentro de CLT.
- El CI no sufre esto porque corre en un runner con Xcode instalado.

### Gatekeeper bloquea `dist/IAPDesktopMac.app` (app sin firma)

- **Síntoma**: al hacer doble clic en `dist/IAPDesktopMac.app`, macOS
  dice que no se puede abrir porque no es de un desarrollador
  identificado (o el binario está "dañado").
- **Causa**: `tools/make-app-bundle.sh` genera el bundle sin firma ni
  notarización (llegan en M4, ver ADRs); es esperado en este estado del
  proyecto.
- **Solución**: clic derecho (o Control-clic) sobre
  `dist/IAPDesktopMac.app` → **Abrir**, y confirmar en el diálogo. Solo
  hace falta la primera vez; macOS recuerda la excepción para ese
  bundle. Alternativa por terminal:

  ```bash
  xattr -dr com.apple.quarantine dist/IAPDesktopMac.app
  ```

## 7. Client OAuth: sin secretos en el repo (GH-80)

El repo **no lleva client ID ni client secret**: `resources/Info.plist` solo
tiene los placeholders `__OAUTH_CLIENT_ID__` y `__OAUTH_CLIENT_SECRET__`, que
cuentan como "no configurado". Cada desarrollador o usuario aporta su propio
cliente OAuth de tipo **Desktop app**, por el entorno o con un fichero local.

### Orden de resolución (`ClientIDStore`)

1. **Override manual** (`UserDefaults`, clave `oauth.clientID`, por perfil):
   el enlace *Use a different OAuth client…* de la ventana Sign In. Solo el
   client ID; guardarlo vacío borra el override.
2. **`Info.plist`** (`OAuthClientID` / `OAuthClientSecret`): solo si un build
   de distribución los inyecta al empaquetar. Los placeholders cuentan como
   ausentes. **Nunca se commitean valores reales.**
3. **Variables de entorno** `GOOGLE_OAUTH_CLIENT_ID` y
   `GOOGLE_OAUTH_CLIENT_SECRET`.
4. **Fichero local** `~/.config/iap-desktop-mac/secrets.env` (o
   `$XDG_CONFIG_HOME/iap-desktop-mac/secrets.env`), leído **solo si existe**.
   El entorno manda sobre el fichero, clave a clave.

Si falta el client ID, la app no falla: la ventana Sign In muestra el campo y
un enlace a Google Cloud Console, y los refresh fallan con un mensaje que dice
qué variables o fichero configurar. `ClientIDStore.missingConfiguration`
distingue si falta el client ID o solo el secret.

### Crear tu cliente OAuth

1. En [Google Cloud Console → Credentials](https://console.cloud.google.com/apis/credentials)
   (Google Auth Platform → Clients) crea un cliente OAuth de tipo
   **Desktop app**. Si el proyecto aún no tiene pantalla de consentimiento,
   configúrala antes (scopes `cloud-platform`, `openid` y `email`).
2. Copia el **client ID** (`<número>-<id>.apps.googleusercontent.com`) y el
   **client secret** (los clientes Desktop de Google lo piden en `/token`).

### Opción A: variables de entorno

```bash
export GOOGLE_OAUTH_CLIENT_ID="YOUR_CLIENT_ID.apps.googleusercontent.com"
export GOOGLE_OAUTH_CLIENT_SECRET="YOUR_CLIENT_SECRET"
swift run App   # o .build/debug/App
```

Una app abierta desde Finder (`open dist/IAPDesktopMac.app`) **no hereda** las
variables de tu shell: para el `.app` usa la opción B.

### Opción B: fichero local (recomendada para el `.app`)

```bash
mkdir -p ~/.config/iap-desktop-mac
cat > ~/.config/iap-desktop-mac/secrets.env <<'ENV'
# Cliente OAuth "Desktop app" propio. Este fichero NO está en el repo.
GOOGLE_OAUTH_CLIENT_ID=YOUR_CLIENT_ID.apps.googleusercontent.com
GOOGLE_OAUTH_CLIENT_SECRET=YOUR_CLIENT_SECRET
ENV
chmod 600 ~/.config/iap-desktop-mac/secrets.env
```

Formato `CLAVE=valor` por línea; admite `#` como comentario, el prefijo
`export ` y comillas. Solo se leen esas dos claves; las demás se ignoran.
Por seguridad **se ignora el fichero si otros usuarios pueden modificarlo**
(permisos de escritura de grupo u otros): alguien podría poner su propio
cliente OAuth. Los valores nunca aparecen en logs; el log solo dice qué
claves se cargaron.

El fichero vive fuera del repo, así que no se puede commitear por accidente.
No lo copies dentro del árbol del proyecto.

### Si un secret se expone

El client secret de una app instalada es extraíble de cualquier binario que
lo lleve, y un valor que estuvo commiteado sigue en el historial de git
aunque se borre después. Si eso pasa, **genera otro secret en Cloud Console
y revoca el anterior**; borrarlo del repo no basta.

**Usa siempre un cliente propio.** No uses el client ID de otra aplicación,
aunque sea público (p. ej. el del IAP Desktop de Google): la pantalla de
consentimiento y la consola de administración mostrarían esa otra app como
titular de los tokens, y la confianza que un administrador le haya dado se
aplicaría sin saberlo a este programa.

### PKCE con `client_secret` opcional

El login usa el flujo para apps instaladas con **PKCE (S256)** y redirect a
loopback. En la [documentación de Google para apps
instaladas](https://developers.google.com/identity/protocols/oauth2/native-app),
`client_secret` figura como **opcional** tanto en el canje del código
(`/token` con `code_verifier`) como en el refresh: `TokenClient` solo lo
envía cuando está configurado (entorno, `secrets.env` o un `Info.plist` de distribución).

### Limitaciones a tener en cuenta

- **Entorno y `.app`.** El binario suelto `.build/debug/App` (y
  `tools/snapshot.sh`) hereda las variables de la shell; el `.app` abierto
  desde Finder no, y por eso para él va mejor `secrets.env`.
- **App no verificada por Google.** A diferencia del original (cliente de
  Google, verificado), un cliente propio con usuarios externos muestra el
  aviso "Google hasn't verified this app" y, en modo *Testing*, solo
  admite los usuarios de prueba que añadas en Cloud Console. Para uso
  interno de una organización, marca la pantalla de consentimiento como
  *Internal*.

### Sign Out

El menú de la app (junto a *Sign In…*) tiene **Sign Out**, sin atajo de
teclado. Al pulsarlo:

1. Intenta revocar el refresh token en Google
   (`POST https://oauth2.googleapis.com/revoke`) — best-effort, no bloquea
   si falla.
2. Borra la entrada de Keychain (`com.iap-mac.auth`) asociada a la cuenta,
   solo si sigue coincidiendo con el token que se está revocando.
3. Limpia el estado en memoria (credencial, access token) y notifica a la
   UI para volver a mostrar la ventana de Sign In.

El override manual del client ID (`UserDefaults` → `oauth.clientID`, ver
arriba) **no se borra** al hacer Sign Out: es un ajuste de build, no de
sesión.

## 8. VM Ops: start/stop/reset/suspend/resume

Las operaciones de VM están en el **menú contextual** del Explorer (clic
derecho sobre una instancia); no hay toolbar ni atajo de teclado todavía.
Las opciones visibles dependen del estado actual de la VM:

- VM en ejecución → `Stop`, `Reset`, `Suspend`.
- VM detenida/suspendida → `Start`, `Resume`.
- Estado desconocido → sin opciones de control.

Cada acción pide confirmación con un diálogo (`¿Stop my-vm?` /
`¿Reset my-vm?` / etc., estilo *warning* para `Reset` por ser destructiva)
indicando el proyecto/zona donde se ejecutará. Al confirmar, la app llama
a la Compute API (`.../instances/{name}/{start|stop|reset|suspend|resume}`)
y espera a que la operación de zona termine (hasta ~2 min) antes de
refrescar el árbol. Si falla, se muestra un segundo diálogo con el motivo
(estado HTTP/razón de la API) sin reintentar automáticamente.

## 9. Añadir proyectos: autodiscover vs manual

Al arrancar, la app intenta **autodiscover**: lista los proyectos
accesibles con la cuenta activa (`resourcemanager.projects.list`) y carga
sus instancias. Si esa llamada falla con **403 `SERVICE_DISABLED`** (la
Cloud Resource Manager API no está habilitada en el proyecto del cliente
OAuth), la barra de estado muestra un aviso con el enlace de activación de
Google Cloud Console y, si ya había proyectos añadidos a mano, sigue
mostrándolos igual. El mensaje incluye también el comando de `gcloud`
equivalente para habilitarla:

```bash
gcloud services enable cloudresourcemanager.googleapis.com
```

Cuando el 403 es por falta de permiso de listado (no por API deshabilitada)
la salida es **Add project** (File → *Add project…*, ⌘N, o el botón de la
toolbar): pide un `project-id` (minúsculas/dígitos/guiones, 6–30
caracteres) y lo añade a una lista persistida en `UserDefaults`
(`knownProjectIDs`); esos IDs se cargan directo vía Compute, sin depender
del listado de Resource Manager. Es la vía recomendada para cuentas de
servicio o usuarios sin el rol de listado a nivel organización.

## 10. Reconexión SSH

El túnel IAP bajo una sesión SSH se reintenta solo: si la conexión
WebSocket se corta, `TunnelKit`/`SSHKit` reconectan de forma transparente
(`reconnect?sid&ack`, con backoff) y la sesión de shell sigue funcionando
sin que el usuario tenga que hacer nada, hasta un número máximo de
intentos.

**Limitación actual:** si se agotan los reintentos, la sesión queda en un
estado "perdido" (`SshLinkState.lost`) a nivel de librería, pero **todavía
no hay un botón "Reconnect" en la UI** (`TerminalUI`/pestaña de sesión) —
la pestaña se queda sin más tráfico y hay que cerrarla y volver a conectar
desde el Explorer. Ver `specs/ssh/design.md` y la tarea `T-SSH-6` (sin
completar) para el diseño previsto de la reconexión manual end-to-end.

## 11. Release: firma, notarización y DMG (GH-62, M4)

Paridad `docs/feature-parity.md` §13: Developer ID + Hardened Runtime +
notarización, Universal Binary (arm64+x86_64), DMG. El workflow
`.github/workflows/release.yml` automatiza todo esto en tags `v*`; esta
sección documenta qué hace y cómo reproducirlo en local.

### 11.1 Qué dispara el release

Un `git push` de un tag con el patrón `v*` (p. ej. `v0.4.0`) lanza el
job `release` en un runner `macos-15`: build release Universal Binary →
empaquetado `.app` → firma + notarización (`tools/sign-and-notarize.sh`) →
DMG → artefacto adjunto a un **borrador** de GitHub Release
(`draft: true`; revisar y publicar manualmente). Pushes a ramas normales o
PRs **no** disparan este workflow (solo `ci.yml`, que no firma nada).

### 11.2 Entitlements (`resources/IAPDesktopMac.entitlements`)

Mínimo necesario para que la app firmada con Hardened Runtime siga
funcionando, cada uno con una razón de uso concreta en el código:

| Entitlement | Por qué |
|---|---|
| `com.apple.security.network.client` | Conexiones salientes: OAuth/Google APIs (`AuthKit`/`GCPClient`), WebSocket IAP (`TunnelKit`). |
| `com.apple.security.network.server` | `IapListener` abre un listener TCP en `127.0.0.1` (puerto efímero) para SSH/RDP/clientes arbitrarios. |
| `keychain-access-groups` | Acceso al Keychain del propio bundle ID (`AuthKit.KeychainStore`, `SettingsStore`, `KeychainHostKeyStore`, credenciales RDP). |

La app **no** usa App Sandbox (distribución directa vía Developer ID, no
Mac App Store); no se añaden entitlements de sandbox ni de dispositivos
(cámara/micrófono/USB) porque no hay código que los use.

### 11.3 Credenciales de firma/notarización: solo por entorno, nunca en el repo

`tools/sign-and-notarize.sh` **nunca** acepta un certificado o contraseña
como argumento ni los lee de un archivo del repo. Todo entra por variables
de entorno que el propio script valida al arrancar (falla rápido si falta
alguna):

| Variable | Contenido |
|---|---|
| `DEVELOPER_ID_APPLICATION` | Identidad de firma exacta (`security find-identity -v -p codesigning`). |
| `NOTARY_APPLE_ID` | Apple ID para notarytool (alternativa: `NOTARY_KEYCHAIN_PROFILE`). |
| `NOTARY_TEAM_ID` | Team ID de Apple Developer. |
| `NOTARY_PASSWORD` | **App-specific password**, nunca la contraseña normal del Apple ID. |
| `NOTARY_KEYCHAIN_PROFILE` (opcional, uso local) | Nombre de un perfil ya guardado con `xcrun notarytool store-credentials`; sustituye a las tres variables de Apple ID/team/password. |

En GitHub Actions estas credenciales viven como **repository/environment
secrets** (`Settings → Secrets and variables → Actions`), nunca en el YAML
ni en el historial de commits:

- `DEVELOPER_ID_APPLICATION`
- `DEVELOPER_ID_CERTIFICATE_P12_BASE64` (certificado `.p12` exportado de
  Keychain Access, codificado en base64: `base64 -i Certificado.p12`)
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD` (password arbitrario para el llavero temporal que
  crea el runner; no es la contraseña de nada existente)
- `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`

El workflow importa el `.p12` a un llavero temporal del runner, firma,
notariza y **borra el llavero al final** (paso `if: always()`), aunque el
job falle a mitad de camino.

### 11.4 Reproducir la firma en local (con certificado propio)

Requiere tener ya un certificado **Developer ID Application** válido
importado en el llavero local (Apple Developer Program):

```bash
tools/make-app-bundle.sh release

export DEVELOPER_ID_APPLICATION="Developer ID Application: Tu Empresa (TEAMID)"
# Opción A: perfil guardado una vez con notarytool (recomendado en local)
xcrun notarytool store-credentials "iap-desktop-mac" \
  --apple-id "tu@apple.id" --team-id TEAMID --password "app-specific-password"
export NOTARY_KEYCHAIN_PROFILE="iap-desktop-mac"
# Opción B: variables sueltas (equivalente a CI)
# export NOTARY_APPLE_ID=... NOTARY_TEAM_ID=... NOTARY_PASSWORD=...

tools/sign-and-notarize.sh
```

Resultado: `dist/IAPDesktopMac.app` firmado+stapled y `dist/IAPDesktopMac.dmg`.
Sin certificado real, el script falla rápido en el primer `codesign` (o
antes, si falta alguna variable de entorno) — no hay modo "simulado".

### 11.5 Troubleshooting del release

- **`security: SecKeychainItemImport: ... MAC verification failed`**: el
  `.p12` o su password no coinciden; regenera el base64 del certificado
  (`base64 -i Certificado.p12 | pbcopy`) y actualiza el secret.
- **`notarytool submit` falla con `Invalid credentials`**: `NOTARY_PASSWORD`
  debe ser un *app-specific password* (appleid.apple.com → Seguridad →
  Contraseñas específicas de app), no la contraseña normal del Apple ID.
- **`The signature does not include a secure timestamp`**: falta red
  durante `codesign --timestamp` (necesita contactar los servidores de
  Apple); reintentar con conectividad.
- **DMG se genera pero Gatekeeper sigue bloqueando**: falta el `xcrun
  stapler staple` (paso 5 del script) o la notarización no llegó a
  `Accepted`; revisa el log con `xcrun notarytool log <submission-id>`.

## 12. Auto-actualización con Sparkle (GH-83)

La app usa Sparkle 2.9.6 y consulta este appcast estable, publicado como asset
del último GitHub Release:

```text
https://github.com/cbustoso/iap-desktop-mac/releases/latest/download/appcast.xml
```

El menú de la aplicación incluye **Check for Updates…** y **Automatically
Check for Updates**. La segunda opción se guarda en `UserDefaults` bajo
`updates.automaticallyChecks`; está activada por defecto y se puede desactivar
sin telemetría ni perfilado del sistema. Un binario ejecutado directamente con
`swift run App` no tiene clave pública y deja el updater deshabilitado.

### 12.1 Crear y custodiar la clave real (una sola vez, por el dueño)

El dueño debe usar el `generate_keys` incluido por Sparkle; las claves de los
tests se generan sólo en memoria y **no** sirven para releases:

```bash
swift package resolve
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
"$SPARKLE_BIN/generate_keys"                 # genera en Keychain e imprime la pública
umask 077
"$SPARKLE_BIN/generate_keys" -x /ruta/en/volumen-cifrado/sparkle-private-key
```

Guardar la pública impresa como secret de Actions `SPARKLE_PUBLIC_ED_KEY`.
Copiar el contenido del fichero exportado al secret `SPARKLE_PRIVATE_KEY` y
eliminar el fichero temporal de cualquier disco no cifrado. La privada no se
commitea, no se adjunta a un issue/release, no se pega en logs y no se pasa
como argumento de proceso. Conviene mantener una copia offline cifrada con
acceso restringido: perderla impide firmar la cadena normal de updates.

`tools/make-app-bundle.sh release` exige `SPARKLE_PUBLIC_ED_KEY` e inyecta
`SUPublicEDKey` únicamente en el `Info.plist` del `.app` generado. La clave
privada jamás entra al bundle ni al repositorio.

### 12.2 Proceso de cada release

Tras compilar, firmar y notarizar como en §11, colocar el DMG final en un
directorio aislado y generar el appcast. El nombre del tag debe coincidir con
el GitHub Release que alojará los assets:

```bash
export SPARKLE_PUBLIC_ED_KEY='base64-publica-generada-por-el-dueño'
tools/make-app-bundle.sh release
tools/sign-and-notarize.sh

mkdir -p /tmp/iap-sparkle-v0.2.0
cp dist/IAPDesktopMac.dmg /tmp/iap-sparkle-v0.2.0/
# En CI, GitHub inyecta el secret directamente como SPARKLE_PRIVATE_KEY.
# En local, cargar la copia desde almacenamiento cifrado; no activar xtrace.
export SPARKLE_PRIVATE_KEY="$(cat /ruta/en/volumen-cifrado/sparkle-private-key)"
tools/generate-appcast.sh /tmp/iap-sparkle-v0.2.0 v0.2.0
unset SPARKLE_PRIVATE_KEY
```

Subir `IAPDesktopMac.dmg` y `appcast.xml` como assets del mismo release y
publicarlo. Antes de publicar, confirmar que cada `<enclosure>` tiene
`sparkle:edSignature`, que su URL contiene el tag correcto y que
`SUPublicEDKey` del bundle coincide con el par usado. El script entrega la
privada a `generate_appcast --ed-key-file -` por stdin y falla si detecta un
update sin firma.

No regenerar la clave para cada versión. Una rotación accidental deja a las
instalaciones existentes sin una ruta confiable de actualización; si se pierde
o compromete, seguir el procedimiento oficial de rotación de claves de Sparkle.
