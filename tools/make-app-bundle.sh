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
# GH-79: icono (CFBundleIconFile=AppIcon en Info.plist); si aún no se generó
# (tools/generate-app-icon.sh), el bundle queda sin icono custom en vez de
# fallar el build entero.
if [ -f "resources/AppIcon.icns" ]; then
    cp "resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "AVISO: falta resources/AppIcon.icns (ejecuta tools/generate-app-icon.sh)" >&2
fi
echo "OK: $APP"
