#!/bin/bash
# Downloads static ffmpeg builds (arm64 + x86_64) from ffmpeg.martin-riedl.de
# and merges them into a universal binary: Vendor/ffmpeg/ffmpeg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DL="$ROOT/Vendor/downloads/ffmpeg"
OUT="$ROOT/Vendor/ffmpeg"
ARM_PATH="${FFMPEG_ARM64_PATH:-arm64/1789931890_9.0.2}"
X86_PATH="${FFMPEG_X86_PATH:-amd64/1789931006_9.0.2}"
BASE="https://ffmpeg.martin-riedl.de/download/macos"

mkdir -p "$DL" "$OUT"
for pair in "arm64:$ARM_PATH" "amd64:$X86_PATH"; do
    name="${pair%%:*}"; path="${pair#*:}"
    if [ ! -x "$DL/$name/ffmpeg" ]; then
        curl -sSL -o "$DL/ffmpeg-$name.zip" "$BASE/$path/ffmpeg.zip"
        curl -sSL -o "$DL/ffmpeg-$name.zip.sha256" "$BASE/$path/ffmpeg.zip.sha256"
        expected=$(awk '{print $1}' "$DL/ffmpeg-$name.zip.sha256")
        actual=$(shasum -a 256 "$DL/ffmpeg-$name.zip" | awk '{print $1}')
        [ "$expected" = "$actual" ] || { echo "SHA256 mismatch for $name"; exit 1; }
        mkdir -p "$DL/$name" && unzip -q -o "$DL/ffmpeg-$name.zip" -d "$DL/$name"
    fi
done

lipo -create "$DL/arm64/ffmpeg" "$DL/amd64/ffmpeg" -output "$OUT/ffmpeg"
chmod +x "$OUT/ffmpeg"
lipo -info "$OUT/ffmpeg"
"$OUT/ffmpeg" -hide_banner -version | head -1
