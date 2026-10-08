#!/bin/bash
# Builds the app and packs it into dist/Subline-<version>.dmg
#   VERSION=1.0.0 ./scripts/make_dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.0.0}"
export VERSION

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
if [ "${SIGN_IDENTITY:--}" != "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
fi
hdiutil verify "$DMG" >/dev/null && echo "==> verified"
echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
