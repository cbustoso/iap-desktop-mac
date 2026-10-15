#!/bin/sh
# Genera appcast.xml y firma cada update con Sparkle generate_appcast.
# La clave privada entra exclusivamente por SPARKLE_PRIVATE_KEY -> stdin.
set -eu

cd "$(dirname "$0")/.."

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

UPDATES_DIR="${1:-}"
RELEASE_TAG="${2:-${GITHUB_REF_NAME:-}}"
[ -n "$UPDATES_DIR" ] || fail "uso: tools/generate-appcast.sh <directorio-updates> <tag-release>"
[ -d "$UPDATES_DIR" ] || fail "no existe el directorio '$UPDATES_DIR'"
[ -n "$RELEASE_TAG" ] || fail "falta el tag de release (argumento 2 o GITHUB_REF_NAME)"
[ -n "${SPARKLE_PRIVATE_KEY:-}" ] || fail "falta SPARKLE_PRIVATE_KEY"

GENERATOR="${SPARKLE_GENERATE_APPCAST:-}"
if [ -z "$GENERATOR" ]; then
    GENERATOR="$(find .build/artifacts -type f -path '*/bin/generate_appcast' -print -quit)"
fi
[ -n "$GENERATOR" ] && [ -x "$GENERATOR" ] \
    || fail "no se encontró generate_appcast; ejecuta 'swift package resolve' o define SPARKLE_GENERATE_APPCAST"

DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/cbustoso/iap-desktop-mac/releases/download/$RELEASE_TAG/}"

# '-' obliga a generate_appcast a leer la clave desde stdin: no aparece en ps,
# argumentos, temporales ni logs del script.
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$GENERATOR" \
    --ed-key-file - \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    "$UPDATES_DIR"

APPCAST="$UPDATES_DIR/appcast.xml"
[ -s "$APPCAST" ] || fail "generate_appcast no produjo '$APPCAST'"
grep -q '<enclosure' "$APPCAST" || fail "el appcast no contiene updates"
if grep '<enclosure' "$APPCAST" | grep -qv 'sparkle:edSignature='; then
    fail "hay updates sin firma EdDSA; comprueba que la clave coincide con SUPublicEDKey"
fi

echo "OK: $APPCAST generado; updates firmados con EdDSA"
