#!/bin/bash
# Builds build/Subline.app (universal: Apple Silicon + Intel).
#   VERSION=1.0.0 ./scripts/build_app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Subline"
BUNDLE_ID="${BUNDLE_ID:-com.subline.app}"
VERSION="${VERSION:-2.1.1}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
APP="$ROOT/build/$APP_NAME.app"

# Signing: SIGN_IDENTITY when it is set ("-" = ad-hoc, or "Developer ID Application: ..."), otherwise the app's own
# certificate "tihomirov-nick" when it is in the Keychain, otherwise ad-hoc. With that certificate every build has the
# same designated requirement, so permissions survive new versions and installed copies can update themselves (README).
APP_CERT="tihomirov-nick"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q "\"$APP_CERT\""; then
        SIGN_IDENTITY="$APP_CERT"
    else
        SIGN_IDENTITY="-"
    fi
fi

# 1. Dependencies
[ -f Vendor/whisper/lib/libwhisper_all.a ] || ./scripts/build_whisper.sh
[ -x Vendor/ffmpeg/ffmpeg ] || ./scripts/fetch_ffmpeg.sh

# 2. Compile (universal binary)
echo "==> swift build (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 --product "$APP_NAME" 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" || true
BIN="$ROOT/.build/out/Products/Release/$APP_NAME"
[ -x "$BIN" ] || BIN="$ROOT/.build/apple/Products/Release/$APP_NAME"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

# 3. Bundle
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/Fonts" \
         "$APP/Contents/Resources/ru.lproj" "$APP/Contents/Resources/en.lproj"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
strip -x "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
# SwiftPM writes the deployment target into the SDK field of the binary (sdk 13.3). macOS reads that field
# to decide whether the app gets the current design (Liquid Glass on macOS 26 and later), so write the SDK
# the app was really built with.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_OS="$(vtool -show-build "$APP/Contents/MacOS/$APP_NAME" | awk '/minos/ { print $2; exit }')"
vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace \
      -output "$APP/Contents/MacOS/$APP_NAME.sdk" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null
mv "$APP/Contents/MacOS/$APP_NAME.sdk" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"
echo "    macOS $MIN_OS+, SDK $SDK_VERSION"
cp Vendor/ffmpeg/ffmpeg "$APP/Contents/Helpers/ffmpeg"

# Icon: Resources/AppIcon.icon in the Icon Composer format, made by scripts/make_icon.swift (flat: a solid fill and the
# white mark, no glass, shadow or translucency). actool turns it into Assets.car, which macOS 26 shows without the grey
# plate it puts around plain .icns icons, and AppIcon.icns for older systems.
[ -d Resources/AppIcon.icon ] || swift scripts/make_icon.swift
xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 13.3 --app-icon AppIcon \
    --output-partial-info-plist "$ROOT/build/icon-partial.plist" --output-format human-readable-text >/dev/null
[ -f "$APP/Contents/Resources/Assets.car" ] && [ -f "$APP/Contents/Resources/AppIcon.icns" ] || { echo "icon compilation failed"; exit 1; }

# Fonts shipped with the app (put licensed .otf/.ttf files into Fonts/)
font_count=0
while IFS= read -r -d '' f; do
    cp "$f" "$APP/Contents/Resources/Fonts/"
    font_count=$((font_count + 1))
done < <(find Fonts -maxdepth 2 -type f \( -iname '*.otf' -o -iname '*.ttf' -o -iname '*.ttc' -o -iname '*.otc' \) -print0 2>/dev/null)
echo "    fonts bundled: $font_count"
cp Fonts/*.txt "$APP/Contents/Resources/Fonts/" 2>/dev/null || true   # font licenses

# Interface languages: Russian strings are the keys in the code, English comes from Localizable.strings
# (regenerate it with scripts/l10n/make_strings.py after changing texts).
python3 scripts/l10n/make_strings.py >/dev/null
cp Resources/en.lproj/Localizable.strings "$APP/Contents/Resources/en.lproj/"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<STRINGS
CFBundleDisplayName = "$APP_NAME";
CFBundleName = "$APP_NAME";
NSHumanReadableCopyright = "Subline makes subtitles for videos. Speech recognition: whisper.cpp (MIT), video: FFmpeg";
"Video" = "Video";
"Video (other formats)" = "Video (other formats)";
STRINGS
cat > "$APP/Contents/Resources/ru.lproj/InfoPlist.strings" <<STRINGS
CFBundleDisplayName = "$APP_NAME";
CFBundleName = "$APP_NAME";
NSHumanReadableCopyright = "Subline делает субтитры к видео. Распознавание: whisper.cpp (MIT), видео: FFmpeg";
"Video" = "Видео";
"Video (other formats)" = "Видео (другие форматы)";
STRINGS

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>13.3</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSHumanReadableCopyright</key><string>Subline makes subtitles for videos. Speech recognition: whisper.cpp (MIT), video: FFmpeg</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Video</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.video</string>
                <string>public.audiovisual-content</string>
                <string>public.audio</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Video (other formats)</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>mkv</string><string>webm</string><string>avi</string><string>flv</string><string>wmv</string>
                <string>ts</string><string>mts</string><string>m2ts</string><string>3gp</string><string>ogv</string>
                <string>vob</string><string>mxf</string><string>mpg</string><string>mpeg</string><string>m4v</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
printf "APPL????" > "$APP/Contents/PkgInfo"

# 4. Sign (inner code first)
echo "==> codesign ($SIGN_IDENTITY)"
xattr -cr "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP/Contents/Helpers/ffmpeg"
    codesign --force --sign - "$APP"
elif [ "$SIGN_IDENTITY" = "$APP_CERT" ]; then
    # Self-signed: Apple's timestamp service and notarization are not for it, so no hardened runtime either.
    codesign --force --timestamp=none --sign "$APP_CERT" "$APP/Contents/Helpers/ffmpeg"
    codesign --force --timestamp=none --sign "$APP_CERT" "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/ffmpeg"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "    $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /requirement: /p')"
echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
lipo -info "$APP/Contents/MacOS/$APP_NAME"
