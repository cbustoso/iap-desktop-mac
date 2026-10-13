#!/bin/sh
# tools/sign-and-notarize.sh — Developer ID + Hardened Runtime + notarytool (GH-62, M4).
#
# Firma dist/IAPDesktopMac.app con un certificado Developer ID Application,
# lo notariza con notarytool, graba el ticket (staple) y empaqueta un DMG.
#
# Credenciales SOLO por variables de entorno, NUNCA en este script ni en el
# repo (ver docs/usage.md "Release" para cómo exportarlas, p. ej. desde
# GitHub Actions secrets o un llavero local). El script falla rápido si
# falta alguna, en vez de intentar firmar/notarizar a medias.
#
# Variables de entorno requeridas:
#   DEVELOPER_ID_APPLICATION   Identidad de firma exacta tal como aparece en
#                              `security find-identity -v -p codesigning`,
#                              p. ej. "Developer ID Application: Mi Empresa (TEAMID)".
#   NOTARY_APPLE_ID            Apple ID usado para notarytool.
#   NOTARY_TEAM_ID             Team ID de Apple Developer (10 caracteres).
#   NOTARY_PASSWORD            App-specific password (NUNCA la contraseña
#                              normal del Apple ID) o referencia a un
#                              Keychain profile ya guardado con
#                              `xcrun notarytool store-credentials`.
#
# Variable opcional:
#   NOTARY_KEYCHAIN_PROFILE    Si está definida, se usa
#                              `--keychain-profile "$NOTARY_KEYCHAIN_PROFILE"`
#                              en vez de Apple ID + team ID + password sueltos
#                              (recomendado para uso local interactivo: las
#                              credenciales quedan en el llavero del usuario,
#                              nunca en variables de entorno de CI).
#
# Uso:
#   tools/sign-and-notarize.sh [dist/IAPDesktopMac.app]
#
# Requiere: Xcode command line tools (codesign, xcrun notarytool, hdiutil),
# un certificado Developer ID Application ya importado en el llavero, y
# dist/IAPDesktopMac.app ya generado (tools/make-app-bundle.sh release).

set -eu

APP="${1:-dist/IAPDesktopMac.app}"
ENTITLEMENTS="resources/IAPDesktopMac.entitlements"
DMG_NAME="IAPDesktopMac.dmg"
DMG_VOLUME_NAME="IAP Desktop Mac"

cd "$(dirname "$0")/.."

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "falta el comando '$1' (Xcode command line tools)."
}

require_env() {
    eval "value=\${$1:-}"
    if [ -z "$value" ]; then
        fail "falta la variable de entorno \$$1. Ver docs/usage.md sección Release."
    fi
}

[ -d "$APP" ] || fail "no existe '$APP'. Genera primero con: tools/make-app-bundle.sh release"
[ -f "$ENTITLEMENTS" ] || fail "no existe '$ENTITLEMENTS'."

require_command codesign
require_command xcrun
require_command hdiutil
require_command ditto

require_env DEVELOPER_ID_APPLICATION

USE_KEYCHAIN_PROFILE=0
if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    USE_KEYCHAIN_PROFILE=1
else
    require_env NOTARY_APPLE_ID
    require_env NOTARY_TEAM_ID
    require_env NOTARY_PASSWORD
fi

echo "== 1/5: codesign (Hardened Runtime, entitlements, timestamp) =="
# --options runtime: Hardened Runtime, obligatorio para notarización.
# --timestamp: firma con sello de tiempo seguro (requisito de notarytool).
# -f: resigna si ya había una firma previa (p. ej. de un intento anterior).
codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$APP"

echo "== 2/5: verificación de firma =="
codesign --verify --deep --strict --verbose=2 "$APP"

echo "== 3/5: empaquetar en .zip para notarytool =="
ZIP_PATH="dist/IAPDesktopMac-notarize.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"

echo "== 4/5: notarytool submit (bloqueante, espera el resultado) =="
if [ "$USE_KEYCHAIN_PROFILE" = "1" ]; then
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
        --wait
else
    xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" \
        --wait
fi

echo "== 5/5: staple + DMG =="
xcrun stapler staple "$APP"
codesign --verify --deep --strict "$APP"

DMG_PATH="dist/$DMG_NAME"
rm -f "$DMG_PATH"
DMG_STAGING="dist/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
ditto "$APP" "$DMG_STAGING/$(basename "$APP")"
hdiutil create -volname "$DMG_VOLUME_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_STAGING" "$ZIP_PATH"

echo "OK: $APP firmado + notarizado + stapled; DMG en $DMG_PATH"
