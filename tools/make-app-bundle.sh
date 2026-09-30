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
echo "OK: $APP"
