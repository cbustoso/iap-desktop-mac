#!/bin/sh
# Genera dist/IAPDesktopMac.app (doble clic) a partir del binario SPM.
# Sin firma: el primer arranque pide confirmación (clic derecho → Abrir).
# La firma/notarización llegan en M4 (CBU-13).
set -e
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="dist/IAPDesktopMac.app"

swift build -c "$CONFIG"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/App" "$APP/Contents/MacOS/App"
cp "resources/Info.plist" "$APP/Contents/Info.plist"

# GH-83: Sparkle es un framework dinámico. SPM lo enlaza, pero al construir
# fuera de Xcode debemos incrustarlo preservando symlinks y permisos.
SPARKLE_FRAMEWORK="$(find .build/artifacts -type d -name Sparkle.framework -print -quit)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "ERROR: Sparkle.framework no está resuelto en .build/artifacts" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

# La clave EdDSA pública no es un secreto, pero debe corresponder a la privada
# custodiada por el dueño. Se inyecta sólo en el bundle; nunca se toca el plist
# fuente ni se admite una clave privada aquí.
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    KEY_SIZE="$(printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')"
    if [ "$KEY_SIZE" != "32" ]; then
        echo "ERROR: SPARKLE_PUBLIC_ED_KEY no es una clave Ed25519 base64 de 32 bytes" >&2
        exit 1
    fi
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
elif [ "$CONFIG" = "release" ]; then
    echo "ERROR: falta SPARKLE_PUBLIC_ED_KEY para un bundle release actualizable" >&2
    exit 1
else
    echo "AVISO: build debug sin SPARKLE_PUBLIC_ED_KEY; el actualizador queda deshabilitado" >&2
fi
# GH-79: icono (CFBundleIconFile=AppIcon en Info.plist); si aún no se generó
# (tools/generate-app-icon.sh), el bundle queda sin icono custom en vez de
# fallar el build entero.
if [ -f "resources/AppIcon.icns" ]; then
    cp "resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "AVISO: falta resources/AppIcon.icns (ejecuta tools/generate-app-icon.sh)" >&2
fi
echo "OK: $APP"
