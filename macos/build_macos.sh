#!/bin/sh
# build_macos.sh [output] - builds Crypto Connection Miner 0.10.2, CPU edition, for macOS (Chipcoin on the CPU, no dev fee).
#   Default target: Apple Silicon (arm64, ARMv8 SHA-256 path). ARCH=x86_64 builds for Intel Macs (SHA-NI / AVX2 / C paths),
#   ARCH=universal builds one binary for both (lipo). Needs the Xcode Command Line Tools (xcode-select --install).
#   MACOSX_DEPLOYMENT_TARGET: oldest macOS that runs the binary (default 11.0, the first macOS for Apple Silicon).
#   The binary is signed ad hoc (required on Apple Silicon); it is not notarized.
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-dev/macos/crypto-connection-miner}"
ARCH="${ARCH:-arm64}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
mkdir -p "$(dirname "$OUT")"
build_one() {
  a="$1"; o="$2"
  echo "clang ($a, macOS $MACOSX_DEPLOYMENT_TARGET+) -> $o"
  B="build/macos-$a"
  mkdir -p "$B"
  clang -arch "$a" -O3 -std=c11 -fno-strict-aliasing -Isrc -c src/chc_cpu.c -o "$B/chc_cpu.o"
  clang -arch "$a" -O3 -std=c11 -Isrc -c src/sha256.c -o "$B/sha256.o"
  clang++ -arch "$a" -O3 -std=c++17 -Isrc -c cpu/ccm_cpu.cpp -o "$B/ccm_cpu.o"
  clang++ -arch "$a" -o "$o" "$B/ccm_cpu.o" "$B/chc_cpu.o" "$B/sha256.o" -lpthread
}
case "$ARCH" in
  universal)
    build_one arm64 "$OUT.arm64"
    build_one x86_64 "$OUT.x86_64"
    lipo -create -output "$OUT" "$OUT.arm64" "$OUT.x86_64"
    rm -f "$OUT.arm64" "$OUT.x86_64" ;;
  *) build_one "$ARCH" "$OUT" ;;
esac
codesign --force --sign - "$OUT" 2>/dev/null || true
file "$OUT"
ls -l "$OUT"
echo "built $OUT"
