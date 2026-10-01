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

## 7. Client ID OAuth: login directo sin pegar nada

Como el IAP Desktop original (que trae su propio client ID), **Sign in abre
el navegador directamente**: el usuario no tiene que crear ni pegar nada si
el build lleva un client ID embebido.

### Orden de resolución (`ClientIDStore`)

1. **Override manual** (`UserDefaults`, clave `oauth.clientID`): el enlace
   discreto *Use a different OAuth client…* de la ventana Sign In muestra el
   campo, ya rellenado con el valor en uso. Guardarlo vacío borra el
   override y vuelve al valor por defecto.
2. **`Info.plist` → `OAuthClientID`**: el valor por defecto del build. Con el
   placeholder `__OAUTH_CLIENT_ID__` (o vacío) cuenta como ausente.
3. **Variable de entorno `GOOGLE_OAUTH_CLIENT_ID`**: para desarrollo.

Si no hay ninguno, la ventana Sign In muestra el campo y un mensaje con
enlace a Google Cloud Console. Pulsar *Sign in* con el valor ya resuelto
**no** lo guarda como override, así que una actualización del client ID
embebido sigue aplicando a quien no haya puesto uno propio.

### Embeber el client ID (maintainer, una sola vez)

1. En [Google Cloud Console → Credentials](https://console.cloud.google.com/apis/credentials)
   (Google Auth Platform → Clients) crea un cliente OAuth de tipo
   **Desktop app**. Si el proyecto aún no tiene pantalla de consentimiento,
   configúrala antes (scopes `cloud-platform`, `openid` y `email`).
2. Copia el **client ID** (`123456789-abc….apps.googleusercontent.com`) y,
   solo si tu cliente lo exige en `/token` (algunas configuraciones devuelven
   `invalid_request: client_secret is missing`), también el **client secret**.
3. Pon ambos en `resources/Info.plist`:

   ```xml
   <key>OAuthClientID</key>
   <string>123456789-abc….apps.googleusercontent.com</string>
   <key>OAuthClientSecret</key>
   <string>GOCSPX-…</string>
   ```

   El secret viaja en `TokenClient` (canje y refresh) y nunca en logs: hay
   tests de redacción que lo garantizan.

4. Genera el bundle con `tools/make-app-bundle.sh`: el script copia ese
   `Info.plist` dentro de `dist/IAPDesktopMac.app`.

**Usa siempre un cliente propio.** No embebas el client ID de otra
aplicación, aunque sea público (p. ej. el del IAP Desktop de Google, que su
documentación publica para que los administradores de Workspace lo
identifiquen): la pantalla de consentimiento y la consola de administración
mostrarían esa otra app como titular de los tokens, que en realidad recibe
este programa, y la confianza que un administrador haya dado a esa app se
aplicaría sin saberlo a esta.

El client ID de una app instalada **no es secreto** (Google lo indica así:
el cliente no puede mantener confidencial nada embebido), por eso puede ir
en el `Info.plist`. El client secret embebido **sí es extraíble del bundle**:
solo debe ser el del dueño para su propio uso; si se expone, genera otro en
Cloud Console y sustitúyelo (un test verifica que se resuelve y que nunca
aparece en descripciones/logs).

### PKCE con `client_secret` opcional

El login usa el flujo para apps instaladas con **PKCE (S256)** y redirect a
loopback. En la [documentación de Google para apps
instaladas](https://developers.google.com/identity/protocols/oauth2/native-app),
`client_secret` figura como **opcional** tanto en el canje del código
(`/token` con `code_verifier`) como en el refresh: `TokenClient` solo lo
envía cuando está configurado (Info.plist o `GOOGLE_OAUTH_CLIENT_SECRET`).

### Limitaciones a tener en cuenta

- **Solo el `.app` lee el `Info.plist`.** El binario suelto
  `.build/debug/App` (y `tools/snapshot.sh`) no tiene `Info.plist`: ahí el
  client ID embebido no existe y hay que exportar
  `GOOGLE_OAUTH_CLIENT_ID` o usar el override de la ventana Sign In.
- **App no verificada por Google.** A diferencia del original (cliente de
  Google, verificado), un cliente propio con usuarios externos muestra el
  aviso "Google hasn't verified this app" y, en modo *Testing*, solo
  admite los usuarios de prueba que añadas en Cloud Console. Para uso
  interno de una organización, marca la pantalla de consentimiento como
  *Internal*.
