#!/bin/sh
# GH-79: regenera resources/AppIcon.iconset (PNGs dibujados por código, sin
# assets externos) y lo convierte a resources/AppIcon.icns con iconutil.
# Ejecutar solo cuando se quiera actualizar el diseño del icono; el .icns
# generado SÍ se commitea (tools/make-app-bundle.sh lo copia al bundle).
set -e
cd "$(dirname "$0")/.."

ICONSET="resources/AppIcon.iconset"
ICNS="resources/AppIcon.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift tools/generate-app-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICNS"
echo "OK: $ICNS"
