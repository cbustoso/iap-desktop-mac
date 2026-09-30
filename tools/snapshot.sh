#!/bin/sh
# Capturas de la ventana principal en modo claro y oscuro (sin permiso de
# grabación de pantalla: la app se renderiza a sí misma y sale).
# Uso: tools/snapshot.sh [dir-salida] [node-id]   (p. ej. instance:demo-web/europe-west1-b/web-01)
set -e
cd "$(dirname "$0")/.."

OUT="${1:-dist/snapshots}"
SELECT="${2:-instance:demo-web/europe-west1-b/web-01}"
mkdir -p "$OUT"
swift build
for MODE in light dark; do
    IAP_SNAPSHOT="$OUT/explorer-$MODE.png" IAP_SNAPSHOT_SELECT="$SELECT" \
        IAP_SNAPSHOT_APPEARANCE="$MODE" .build/debug/App
    echo "OK: $OUT/explorer-$MODE.png"
done
