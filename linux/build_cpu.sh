#!/bin/sh
# build_cpu.sh [output] - builds Crypto Connection Miner 0.10.2, CPU edition, for Linux (Chipcoin on the CPU, no GPU, no CUDA).
#   x86-64: SHA-NI / AVX2 / portable C paths chosen at run time. arm64 (aarch64): ARMv8 SHA-256 path when the CPU has it
#   (built with -march=armv8-a+crypto, checked at run time with the kernel's hwcaps), portable C otherwise.
#   CC / CXX: compilers (default gcc / g++; aarch64-linux-gnu-gcc / -g++ to cross-build for arm64). STATIC=1: static binary.
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-dev/linux/crypto-connection-miner-cpu}"
CC="${CC:-gcc}"
CXX="${CXX:-g++}"
MACH=$($CC -dumpmachine)
ARCHFLAGS=""
case "$MACH" in aarch64*|arm64*) ARCHFLAGS="-march=armv8-a+crypto" ;; esac
LDX=""
[ "${STATIC:-0}" = "1" ] && LDX="-static"
B="build/cpu-$MACH"
mkdir -p "$B" "$(dirname "$OUT")"
"$CC" $ARCHFLAGS -O3 -std=c11 -fno-strict-aliasing -Isrc -c src/chc_cpu.c -o "$B/chc_cpu.o"
"$CC" $ARCHFLAGS -O3 -std=c11 -Isrc -c src/sha256.c -o "$B/sha256.o"
"$CXX" $ARCHFLAGS -O3 -std=c++17 -Isrc -c cpu/ccm_cpu.cpp -o "$B/ccm_cpu.o"
"$CXX" $LDX -o "$OUT" "$B/ccm_cpu.o" "$B/chc_cpu.o" "$B/sha256.o" -pthread
echo "built $OUT ($MACH)"
ls -l "$OUT"
