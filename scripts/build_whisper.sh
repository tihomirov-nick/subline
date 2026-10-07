#!/bin/bash
# Builds whisper.cpp as a universal (arm64 + x86_64) static library for the app.
# Result: Vendor/whisper/lib/libwhisper_all.a + headers in Sources/CWhisper/include
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_VERSION="${WHISPER_VERSION:-1.9.4}"
SRC="$ROOT/Vendor/downloads/whisper.cpp-$WHISPER_VERSION"
OUT="$ROOT/Vendor/whisper"
MACOS_MIN=13.3

if [ ! -d "$SRC" ]; then
    mkdir -p "$ROOT/Vendor/downloads"
    curl -sSL -o "$ROOT/Vendor/downloads/whisper.cpp-$WHISPER_VERSION.tar.gz" \
        "https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v$WHISPER_VERSION"
    tar xzf "$ROOT/Vendor/downloads/whisper.cpp-$WHISPER_VERSION.tar.gz" -C "$ROOT/Vendor/downloads"
fi

COMMON=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN
    -DBUILD_SHARED_LIBS=OFF
    -DWHISPER_BUILD_EXAMPLES=OFF
    -DWHISPER_BUILD_TESTS=OFF
    -DWHISPER_BUILD_SERVER=OFF
    -DWHISPER_CURL=OFF
    -DWHISPER_SDL2=OFF
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DGGML_CCACHE=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_METAL_USE_BF16=ON
    -DGGML_BLAS=ON
    -DGGML_ACCELERATE=ON
)

build_arch() {
    local arch=$1; shift
    local dir="$SRC/build-app-$arch"
    rm -rf "$dir"
    cmake -S "$SRC" -B "$dir" "${COMMON[@]}" -DCMAKE_OSX_ARCHITECTURES=$arch "$@" > "$dir.log" 2>&1
    cmake --build "$dir" --config Release -j "$(sysctl -n hw.ncpu)" >> "$dir.log" 2>&1
    local libs
    libs=$(find "$dir" -name "*.a" | sort)
    echo "[$arch] static libs:"; echo "$libs" | sed 's/^/   /'
    libtool -static -o "$dir/libwhisper_all.a" $libs 2>/dev/null
}

build_arch arm64
build_arch x86_64 -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON

mkdir -p "$OUT/lib"
lipo -create "$SRC/build-app-arm64/libwhisper_all.a" "$SRC/build-app-x86_64/libwhisper_all.a" \
     -output "$OUT/lib/libwhisper_all.a"
lipo -info "$OUT/lib/libwhisper_all.a"

INC="$ROOT/Sources/CWhisper/include"
mkdir -p "$INC"
cp "$SRC/include/whisper.h" "$INC/"
for h in ggml.h ggml-cpu.h ggml-backend.h ggml-alloc.h; do
    cp "$SRC/ggml/include/$h" "$INC/"
done
cp "$SRC/LICENSE" "$INC/LICENSE-whisper.cpp.txt"   # MIT notice for the copied headers
echo "$WHISPER_VERSION" > "$OUT/VERSION"
echo "whisper.cpp $WHISPER_VERSION built OK"
