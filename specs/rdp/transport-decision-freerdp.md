# T-RDP-4 — Decisión FreeRDP embebido (spike)

Fecha: 2026-10-13 · GH-56 · FreeRDP 3.32.2

## Decisión: no integrar FreeRDP en esta fase; mantener `.rdp` como vía principal

**Veredicto de producto: NO-GO por ahora para FreeRDP embebido vía SPM-C/XCFramework.**
El motor FreeRDP sí cubre NLA/CredSSP y permite render nativo en una `NSView`; no hay un
bloqueo de protocolo o de AppKit. El bloqueo es de entrega: upstream no publica un
paquete SPM ni un XCFramework de macOS, y no se pudo demostrar un artefacto universal
autocontenido con FreeRDP + WinPR + OpenSSL + canales que pase firma, Hardened Runtime y
notarización. Fabricar y mantener ese SDK es una línea de producto/supply-chain propia,
no un binding pequeño.

Se continúa con `RdpFileFallback`/Windows App. La rama embebida solo debe reabrirse con
una tarea explícita para producir, fijar y notarizar un XCFramework reproducible y
probarlo contra un Windows Server real con NLA.

## Matriz de viabilidad

| Puerta | Evidencia | Resultado |
|---|---|---|
| API cliente y NLA/CredSSP | `freerdp.h` 3.32.2 expone `AUTH_NLA`, `AuthenticateEx` y `freerdp_connect`; el core incluye CredSSP/WinPR SSPI. OpenSSL es requerido y es el backend probado por release. | ✅ Viable en el motor |
| Restricted Admin / sesión admin | El cliente común expone las opciones equivalentes a `/restricted-admin` y `/admin`; deben mapearse en el shim C, no importando structs C grandes directamente en Swift. | ✅ API disponible; no probada contra servidor |
| Framebuffer → `NSView` | El cliente oficial `client/Mac/MRDPView.m` ya usa `gdi_init(..., PIXEL_FORMAT_BGRX32)`, crea un bitmap CoreGraphics y dibuja en `NSView`. El spike compila el mismo límite BGRX32 C→Swift→AppKit. | ✅ Viable |
| SPM-C directo | El repo FreeRDP usa CMake, genera headers/config y compone varias librerías; no contiene `Package.swift`. SPM no consume un proyecto CMake como dependencia fuente sin mantener un fork/wrapper y su grafo nativo. | ❌ No hay integración upstream soportada |
| XCFramework listo para uso | Los releases oficiales entregan fuentes, no un XCFramework/macOS SDK. Upstream indica que el cliente Mac no tiene binarios y se construye con su script. | ❌ Hay que producirlo y alojarlo nosotros |
| Universal macOS 14+ | La guía permite `CMAKE_OSX_ARCHITECTURES="arm64;x86_64"` y deployment target, pero cada dependencia y add-in también debe quedar autocontenido y sin rutas Homebrew. No se construyó ese conjunto. | ⚠️ Posible, no demostrado |
| Hardened Runtime | El spike Swift/C sin FreeRDP acepta firma ad-hoc `--options runtime` y `codesign --verify --strict`. FreeRDP no necesita JIT, por lo que no se anticipan excepciones de runtime; aun así falta probar y firmar todos los Mach-O reales con Developer ID. | ⚠️ Sin bloqueo conocido; gate no superada |
| Notarización | Apple exige Developer ID, timestamp, Hardened Runtime y firma válida de todo ejecutable distribuido. No había identidad Developer ID ni artefacto FreeRDP para enviar a `notarytool`. | ❌ No validada |
| Licencia | FreeRDP es Apache-2.0. | ✅ Compatible |

## Spike entregado

`Spikes/FreeRDPEmbedding` es un paquete Swift independiente; no modifica el manifest ni
los targets del producto.

- `CFreeRDPProbe`: target C con una frontera pequeña y estable. Detecta los headers
  `freerdp/freerdp.h` y `freerdp/gdi/gdi.h` sin fingir símbolos ni vendorizar una copia.
- `FreeRDPFramebufferView`: `NSView` AppKit programática que consume desde C un buffer
  BGRX32 con ancho, alto y stride; valida el patrón que usaría `rdpContext.gdi`.
- El ejecutable comprueba dimensiones/stride y reporta explícitamente si FreeRDP está
  disponible. En esta máquina reportó `false`; FreeRDP no estaba instalado.
- No se tocó `Sources/`, el `Package.swift` raíz ni configuración del producto.

Esto prueba la parte SPM-C/AppKit, pero deliberadamente **no se presenta como prueba de
FreeRDP enlazado**. Tal prueba requiere el artefacto que constituye precisamente la
puerta fallida de este spike.

## Evidencia reproducible

Entorno observado:

```text
Apple Swift 6.4; target arm64-apple-macosx26.0
Command Line Tools solamente (xcodebuild: requiere Xcode completo)
cmake: no instalado; pkg-config: no instalado
brew info freerdp: 3.32.2 bottled, no instalado
curl github.com: DNS bloqueado en el sandbox
```

Build y ejecución (se usa `--disable-sandbox` porque el sandbox interno de SwiftPM no
puede anidarse dentro del sandbox de esta sesión):

```sh
cd Spikes/FreeRDPEmbedding
mkdir -p .build/module-cache
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift build --disable-sandbox --scratch-path .build \
  -Xcc -fmodules-cache-path="$PWD/.build/module-cache"
.build/out/Products/Debug/FreeRDPEmbeddingSpike
```

Salida relevante:

```text
Building for debugging...
SPM-C/AppKit framebuffer bridge: OK
FreeRDP headers available: false
FreeRDP headers not found; no supported SPM/XCFramework artifact supplied
```

Comprobación local de Hardened Runtime sobre el binario del spike:

```sh
codesign --force --sign - --options runtime \
  .build/out/Products/Debug/FreeRDPEmbeddingSpike
codesign --verify --strict --verbose=2 \
  .build/out/Products/Debug/FreeRDPEmbeddingSpike
```

```text
valid on disk
satisfies its Designated Requirement
CodeDirectory flags=0x10002(adhoc,runtime)
Format=Mach-O thin (arm64)
```

La firma ad-hoc solo comprueba compatibilidad del ejecutable mínimo con Hardened
Runtime; no sustituye Developer ID ni notarización, y el binario es `arm64`, no el
universal requerido para distribución.

## Fuentes verificadas

- [FreeRDP 3.32.2 release](https://github.com/FreeRDP/FreeRDP/releases/tag/3.32.2):
  release vigente evaluado, publicado como bugfix/security release.
- [Guía oficial de compilación](https://github.com/FreeRDP/FreeRDP/wiki/Compilation):
  macOS desde fuente, arquitectura universal/deployment target y OpenSSL.
- [`CMakeLists.txt` 3.32.2](https://github.com/FreeRDP/FreeRDP/blob/3.32.2/CMakeLists.txt):
  OpenSSL requerido; WinPR, core, channels y clients son subproyectos separados.
- [`freerdp.h` 3.32.2](https://github.com/FreeRDP/FreeRDP/blob/3.32.2/include/freerdp/freerdp.h):
  auth NLA, callbacks, contexto/GDI y ciclo connect.
- [`MRDPView.m`](https://github.com/FreeRDP/FreeRDP/blob/master/client/Mac/MRDPView.m):
  precedente upstream de `NSView` + CoreGraphics + framebuffer GDI.
- [Apple: crear XCFramework](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle):
  librerías C de build alternativo, arquitecturas y firma del XCFramework.
- [Apple: notarización](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution):
  Developer ID, timestamp, firma de ejecutables y Hardened Runtime.

## Riesgos y condición para reconsiderar

1. **Supply chain propia:** hay que fijar FreeRDP, WinPR y OpenSSL, generar SBOM/avisos,
   seguir CVEs y reconstruir rápido. El propio 3.32.2 incluye numerosas correcciones de
   seguridad, por lo que no es razonable congelar un binario sin pipeline de updates.
2. **ABI/API 3.x:** el header marca APIs obsoletas dentro de la misma major; un shim C
   estrecho debe aislar Swift de structs y callbacks cambiantes.
3. **Plugins/canales:** clipboard, audio, smartcard, drive y WebAuthn amplían el grafo y
   las pruebas. Rutas absolutas de plugins o dependencias Homebrew invalidan un bundle
   autocontenido/notarizable.
4. **Credenciales/certificados:** NLA existe, pero falta una prueba contra Windows Server
   real a través de `127.0.0.1:{puerto}` de `TunnelKit`, incluida validación X.509 y
   Restricted Admin.
5. **Distribución:** antes de cambiar el veredicto se exige XCFramework `arm64+x86_64`,
   auditoría de `otool -L`/rpaths, app firmada con Developer ID + Hardened Runtime,
   `notarytool` aceptado y smoke test en una Mac limpia.

Hasta cumplir las cinco puertas, el feature-flag FreeRDP debe permanecer ausente y el
fallback `.rdp` es la única vía soportada.
