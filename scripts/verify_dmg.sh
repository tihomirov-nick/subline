#!/bin/bash
# Checks that the app in a DMG is signed with the app's own certificate "tihomirov-nick": installed copies replace
# themselves only with an app whose signature satisfies their designated requirement (identifier com.subline.app and
# this certificate's leaf hash).
#   ./scripts/verify_dmg.sh dist/Subline-2.1.0.dmg
set -euo pipefail

DMG="${1:?usage: ./scripts/verify_dmg.sh <dmg>}"
APP_NAME="Subline"
BUNDLE_ID="com.subline.app"
LEAF="af82036140843a7d76497ea8e4cd23403c8aedc2"   # SHA-1 of the certificate "tihomirov-nick"

MOUNT="$(mktemp -d -t subline-verify)"
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || hdiutil detach "$MOUNT" -force -quiet; rmdir "$MOUNT" 2>/dev/null || true' EXIT

APP="$MOUNT/$APP_NAME.app"
[ -d "$APP" ] || { echo "no $APP_NAME.app in $DMG"; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "the signature of $APP_NAME.app is not valid"; exit 1; }
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
if ! grep -qi "certificate leaf = H\"$LEAF\"" <<< "$REQUIREMENT" || ! grep -q "identifier \"$BUNDLE_ID\"" <<< "$REQUIREMENT"; then
    echo "$APP_NAME.app is not signed with \"tihomirov-nick\" as $BUNDLE_ID (its requirement: ${REQUIREMENT:-none})"
    echo "Installed copies would not update to it. Put the certificate into the Keychain (README) and build again."
    exit 1
fi
echo "==> $APP_NAME.app in $(basename "$DMG") is signed with \"tihomirov-nick\" ($BUNDLE_ID)"
