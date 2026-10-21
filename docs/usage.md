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
`AzureClient`, `TunnelKit`, `SSHKit`, `TerminalUI`, `SFTPKit`, `RDPBridge`,
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

## 13. Azure: VMs vía Azure Bastion (GH-84, en desarrollo)

> **Estado actual**: en desarrollo. Hay perfiles Azure (#91) con la
> autenticación de la sesión `az login` (`AuthKit`: `AzCliTokenSource`,
> `AzureCredentialFacade`), elección de tenant/suscripción, nodos Azure en el
> Explorer (#92) y el túnel nativo en `BastionKit` (#93/#94) con proxy,
> renovación de sesión y errores tipados (#95). Diseño
> completo en [`specs/azure/`](../specs/azure/):
> [`requirements.md`](../specs/azure/requirements.md),
> [`design.md`](../specs/azure/design.md), [`tasks.md`](../specs/azure/tasks.md) y
> la investigación [`azure-bastion-research.md`](../specs/azure/azure-bastion-research.md)
> (la decisión de autenticación está en su §0.1).

### 13.1 Requisitos: Azure CLI + `az login`

La app **no tiene login Azure propio**: usa la sesión de Azure CLI del usuario.

```bash
brew install azure-cli
az login                       # abre el navegador; usa tu cuenta corporativa
az login --tenant <tenantId>   # si un tenant exige MFA/Conditional Access propio
az account list --output table # comprueba qué ve la sesión
```

- La app busca `az` en el `PATH` y además en `/opt/homebrew/bin`,
  `/usr/local/bin`, `/usr/bin` y `/bin` (un `.app` abierto desde Finder no
  hereda el `PATH` de la shell).
- Pide un token ARM por tenant con
  `az account get-access-token --resource https://management.core.windows.net/ [--tenant <id>] --output json`
  y lo guarda **solo en memoria** hasta que caduca (≈ 1 h). No escribe tokens
  en disco ni en Keychain: los custodia el propio `az`.
- Un perfil Azure guarda solo metadata no sensible: el tenant y el `oid` de la
  cuenta de la sesión `az` (y el UPN enmascarado). Si `az` pasa a otra cuenta
  (otro `az login`), el perfil lo detecta y avisa en lugar de usar esa cuenta.
- Desconectar un perfil olvida sus tokens en memoria, pero **no** ejecuta
  `az logout`: la sesión del CLI es tuya y la comparten otras herramientas.
- Errores con instrucción concreta: `az` no instalado (`brew install
  azure-cli`), sin sesión (`az login`), tenant que pide reautenticación
  (`az login --tenant <id>`), `az` que no responde a tiempo, o cuenta distinta
  a la del perfil.

### 13.2 Crear un perfil Azure y elegir suscripción

1. **Profiles → Add profile…**, nombre y nube **Microsoft Azure (sesión az
   login)**. Los perfiles Google existentes no cambian.
2. Al abrirse (o al arrancar la app con ese perfil), la ventana detecta `az`:
   - sin `az` o sin sesión: estado vacío **«Instala Azure CLI y ejecuta az
     login»** con los comandos, **Abrir Terminal**, **Copiar comandos** y
     **Reintentar** (volver a la app tras `az login` también reintenta). No se
     muestran datos de ejemplo;
   - con sesión: el perfil queda ligado a esa cuenta (tenant + `oid`) y lista
     los tenants y suscripciones de la sesión.
3. Selecciona un tenant o una suscripción y pulsa **Usar selección** (o doble
   clic). La elección se guarda en el perfil; si deja de existir, se usa la
   suscripción por defecto de `az`.
4. **Sign Out** desliga la cuenta del perfil (sin `az logout`); **Refresh**
   (⌘R) vuelve a leer la sesión `az`.

### 13.3 Cómo se detectan cuentas, tenants y suscripciones

1. **Cuenta y tenants**: `az account list --output json` da la cuenta activa y
   los tenants/suscripciones que conoce la sesión. Se completa con ARM
   `GET /tenants` (nombre y dominio del tenant) usando el token de `az`.
2. **Suscripciones**: ARM `GET /subscriptions` con el token de cada tenant
   (estado actual, incluidas las creadas después del `az login`). Si ARM falla,
   se usan las que `az` tenía en su caché. Se omiten las suscripciones
   `Disabled`/`Deleted` y se deduplican las delegadas por Lighthouse.
3. **Recursos**, por suscripción (hasta 4 suscripciones en paralelo): grupos de
   recursos, VMs, NICs y `bastionHosts` vía ARM REST, siguiendo `nextLink` y
   respetando `Retry-After` ante 429/503.
4. **VM ↔ Bastion**: cada VM se asocia al Bastion de la VNet de su NIC
   principal. Aún no se resuelven VNets *peered* ni el estado de encendido de
   la VM.

Un fallo en un tenant o suscripción (permisos, MFA pendiente) se marca en ese
nodo y no impide cargar el resto.

### 13.4 Cómo se abre el túnel

Túnel **nativo en Swift** (`BastionKit`, research §3.3–3.4, ruta 1), sin
delegar en `az network bastion tunnel`:

1. ARM solo se usa para **leer** el Bastion (`dnsName`, SKU, `enableTunneling`);
   no hay ninguna llamada ARM que "abra" el túnel.
2. Por cada conexión TCP, la app pide un token de sesión al plano de datos del
   Bastion (`POST https://{dnsName}/api/tokens`, con el token ARM de `az`). A
   partir de la segunda conexión, el POST **encadena** la sesión anterior
   (`token` + cabecera `X-Node-Id`), como el CLI.
3. Abre un WebSocket `wss://{dnsName}/webtunnelv2/…` (puerto 443) y reenvía por
   él los bytes de SSH (puerto 22) o RDP (3389), igual que hoy con IAP. SSH y
   SFTP van in-process; RDP pasa por un puerto local `127.0.0.1:{efímero}` al
   que se conecta Windows App.
4. Al cerrarse la última conexión (o el perfil), un **único**
   `DELETE /api/tokens/{authToken}` borra la sesión (404 = ya no existía).

Salida de red necesaria: `{dnsName}` del Bastion y `management.azure.com`,
ambos por 443.

**Proxy corporativo** (REQ-AZ-9): se usa el proxy del sistema con el mismo
resolvedor que IAP (incluido PAC; si el PAC falla, conexión directa). El
`POST`/`DELETE` van por `URLSession` con ese proxy y el WebSocket hace
`HTTP CONNECT {dnsName}:443` a través de él. Proxies SOCKS no se usan (directo).
Si el proxy rechaza el `CONNECT` (403, 407 con autenticación), el error es
inmediato: «El proxy no permite la conexión WebSocket hacia el Bastion».

### 13.5 Roles RBAC necesarios

Para conectar con native client, la cuenta de `az` necesita como mínimo
(ver research §2.1):

| Recurso | Rol |
|---|---|
| VM | **Reader** |
| NIC con la IP privada de la VM | **Reader** |
| Recurso Azure Bastion | **Reader** |
| VNet de la VM, si el Bastion está en una VNet *peered* | **Reader** |

- Para el descubrimiento basta **Reader** en la suscripción o el grupo de recursos
  (lo hereda todo lo anterior).
- Estos roles permiten llegar a la VM, no iniciar sesión en ella: el login
  SSH/RDP usa las credenciales del sistema operativo de la VM.

### 13.6 SKU del Bastion: Standard o superior con native client

La app solo puede conectar a través de un Bastion **Standard o Premium** con
**Native Client Support** activado (`enableTunneling = true`). En el portal:
*Bastion → Configuration → Native client support*.

| SKU | Native client | Usable desde la app |
|---|---|---|
| Developer | No | No |
| Basic | No | No |
| Standard | Sí (`enableTunneling`) | **Sí** |
| Premium | Sí (`enableTunneling`) | **Sí** |

Un Bastion Basic o Developer aparecerá en el árbol, pero sin opción de
conectar ("SKU sin native client: actualizar a Standard").

### 13.7 Costo aproximado de Bastion

Precios pay-as-you-go en `eastus` (Azure Retail Prices API, consultada
2026-10-20; research §6.2). Varían por región y en el tiempo; consulta la
[página de precios](https://azure.microsoft.com/en-us/pricing/details/azure-bastion/)
antes de desplegar.

| SKU | USD/hora (2 instancias) | Instancia adicional | ≈ USD/mes (730 h) |
|---|---|---|---|
| Developer | gratis | — | 0 |
| Basic | 0.19 | — | ≈ 139 |
| **Standard** | **0.29** | 0.14 | **≈ 212** |
| Premium | 0.45 | 0.22 | ≈ 329 |

- Bastion se cobra **por hora desde que se despliega**, se use o no.
- Datos salientes: los primeros 5 GB/mes gratis, luego ≈ 0.087 USD/GB.
- Standard cuesta entre 0.29 y 0.362 USD/h según la región.
- Un mismo Bastion da servicio a las VMs de su VNet y de las VNets *peered*, así
  que lo habitual es uno por VNet hub (≈ 212 USD/mes en Standard).

### 13.8 Limitación: RDP con Entra ID no funciona desde macOS

Microsoft solo permite RDP con **Entra ID** a través de Bastion native client
desde PCs **Windows 10+** registrados o unidos a Entra en el mismo directorio que
la VM (research §3.6). Desde un Mac no es posible, ni con esta app ni con `az`.

Alternativas:

- **Credenciales locales o de dominio** (AD DS) de la VM para el login RDP.
- Si la VM solo admite login Entra (sin cuenta local): un **jump host Windows**
  unido a Entra, desde el que se abre el RDP.

SSH no tiene esta limitación con usuario/clave o llave de la VM.

### 13.9 Renovación de sesión y desconexiones

El protocolo del Bastion **no tiene reanudación** (sin SID/ACK, a diferencia del
relay IAP de §10): un WebSocket caído es una conexión TCP muerta. La app:

- **Renueva la sesión al abrir cada conexión.** Si el `POST /api/tokens`
  devuelve 401/403, 429, 5xx, timeout o error de red, lo repite **encadenando la
  misma sesión previa** (`token` + `X-Node-Id`) con backoff exponencial
  (0,5 s → 1 s → … hasta 8 s) y como máximo **3 intentos**. Ante 401/403 pide
  antes un token ARM nuevo a `az`. Ante 404 de una sesión encadenada (el Bastion
  ya la olvidó) pide una sesión nueva sin encadenar.
- **Reintenta el WebSocket** si su upgrade falla con un error reintentable (p.
  ej. `websocketToken` caducado → 401): pide otro POST encadenado (el
  `websocketToken` es de un solo uso) y vuelve a abrirlo, con el mismo backoff.
- **No reintenta** lo que no se arregla repitiendo: SKU sin native client,
  VM/Bastion inexistente (404 sin sesión previa), proxy que bloquea, respuesta
  con formato desconocido. Si se agotan los intentos el error dice «Tras N
  intentos: …» con el último motivo.
- **Detecta cortes a mitad de sesión.** Un ping WebSocket cada 30 s; si no hay
  pong antes del siguiente, el túnel se da por perdido (código 1006). Un cierre
  sin Close 1000 también. En ambos casos la conexión termina **enseguida** con
  `connectionLost` (sin quedarse colgada): la sesión SSH recibe el estado
  `lost` con ese motivo y, en RDP, Windows App ve un reset de la conexión y
  ofrece reconectar; el error tipado queda para la UI (`failures()` del forwarder). La siguiente
  conexión pide una sesión nueva (encadenada si quedan otras abiertas).
- **Cierra limpio**: sea cual sea el camino, un único `DELETE` cuando no queda
  ninguna conexión.

### 13.10 Troubleshooting del túnel

| Mensaje | Causa probable | Qué hacer |
|---|---|---|
| «Azure rechazó el acceso al Bastion o a la VM…» | Falta **Reader** en VM/NIC/Bastion, o la sesión `az` es de otra cuenta | Revisar §13.5; `az account show`; `az login` |
| «Tras 3 intentos: El Bastion devolvió HTTP 503/429» | Bastion saturado o en mantenimiento | Esperar y reintentar; ver *Resource health* del Bastion |
| «El Bastion (SKU …) no admite el túnel nativo…» | SKU Basic/Developer o *Native client support* apagado | §13.6 |
| «El Bastion no encuentra la VM o la sesión ya no existe.» | VM borrada/movida o ID incorrecto | Refrescar (⌘R) el árbol |
| «El proxy no permite la conexión WebSocket hacia el Bastion.» | El proxy bloquea `CONNECT` a `*.bastion.azure.com:443` o exige autenticación | Pedir excepción para `{dnsName}:443`; el proxy con autenticación no está soportado |
| «Se perdió la conexión con el Bastion (código 1006)…» | Sin respuesta a los pings: Wi‑Fi/VPN caída, suspensión del Mac, NAT que expiró | Volver a conectar; si se repite con red estable, ver *Diagnóstico* abajo |
| «Se perdió la conexión con el Bastion.» (sin código) | El Bastion o un intermediario cortó el TCP | Volver a conectar; si pasa siempre a los ~60 min, es R10 (sesión larga) |
| «El Bastion respondió de una forma no reconocida…» | Azure cambió la API no documentada | Abrir issue con el log (sin tokens) |

**Diagnóstico (logs locales).** Los eventos del túnel se registran en OSLog,
solo en tu Mac, sin tokens ni URLs del WebSocket (el nombre de la VM va como
dato privado):

```bash
log stream --level debug --predicate 'subsystem == "com.iapdesktop.mac" && category == "azure.bastion"'
# o, a posteriori:
log show --last 1h --predicate 'subsystem == "com.iapdesktop.mac" && category == "azure.bastion"'
```

Se ven los POST (intento, encadenado o no), reintentos con su retardo y motivo,
token ARM invalidado, fallos del WebSocket, túneles perdidos (con la clase de
error) y el DELETE final.

### 13.11 Validación contra un Bastion real (pre-release)

La batería e2e (REQ-AZ-10) usa el script del spike, que puede ejecutar el
**código de producción** en lugar del spike:

```bash
cd Spikes/BastionSpike
scripts/validate-f0.sh --usar-bastionkit <subscription> <rg-del-bastion> <bastion> <vm> [usuario-ssh]
HOLD_SECS=4000 scripts/validate-f0.sh --usar-bastionkit … <usuario-ssh>   # + sesión > 1 h (R10)
```

`--usar-bastionkit` compila `bastion-check` (producto del `Package.swift` raíz:
`BastionKit` + `AzureClient` + `AzCliTokenSource`, con proxy del sistema y
renovación) y comprueba lo mismo que con el spike: banner SSH, contraste con
`az network bastion tunnel`, DELETE 200/204 y segundo DELETE 404, y que el log no
contiene tokens. `bastion-check` también se puede usar a mano:

```bash
swift run bastion-check --subscription <id> --resource-group <rg> --bastion <b> --vm <vm> \
  --port 22 --listen-port 50022 --verbose
ssh -p 50022 usuario@127.0.0.1
```

