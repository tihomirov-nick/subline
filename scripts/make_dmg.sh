#!/bin/bash
# Builds the app and packs it into dist/Subline-<version>.dmg
#   VERSION=1.0.0 ./scripts/make_dmg.sh
# The app is signed with its own certificate "tihomirov-nick": only copies signed with it can update themselves to
# the next release (README). Without the certificate the app is signed ad-hoc, with a loud warning.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-2.2.0}"
export VERSION

APP_CERT="tihomirov-nick"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q "\"$APP_CERT\""; then
        SIGN_IDENTITY="$APP_CERT"
    else
        SIGN_IDENTITY="-"
        echo "!!! ================================================================================="
        echo "!!! The certificate \"$APP_CERT\" is not in the Keychain, so Subline is signed ad-hoc."
        echo "!!! A copy installed from this DMG CANNOT UPDATE ITSELF and asks for permissions again"
        echo "!!! after every new version. Restore the certificate from its backup (README) and rebuild."
        echo "!!! ================================================================================="
    fi
fi
export SIGN_IDENTITY

./scripts/build_app.sh

STAGE="$ROOT/build/dmg"
DMG="$ROOT/dist/Subline-$VERSION.dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$ROOT/dist"
cp -R "$ROOT/build/Subline.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/Как установить.txt" "$ROOT/docs/How to install.txt" "$STAGE/"

rm -f "$DMG"
echo "==> creating $DMG"
hdiutil create -volname "Subline $VERSION" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
# A Developer ID signs the disk image too; the self-signed certificate is only for the app inside.
if [ "$SIGN_IDENTITY" != "-" ] && [ "$SIGN_IDENTITY" != "$APP_CERT" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
fi
hdiutil verify "$DMG" >/dev/null && echo "==> verified"
echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
