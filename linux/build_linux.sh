#!/bin/bash
# build_linux.sh [output] - builds the Linux x86-64 Crypto Connection Miner 0.10 (multi-coin NVIDIA miner: gostd GOSTcoin,
#   lyra2v2 Bitmark, neoscrypt Feathercoin, ting Daler, equihash192 Ycash, ethash NEX Chain, chc Chipcoin; no dev fee) with CUDA 12.9.
#   CUDA: $CUDA_HOME (default ~/cuda/12.9 or /usr/local/cuda-12.9); gcc / g++ 11 or later. Since 0.9.0 the release
#   binary is built with gcc-11 / g++-11 when they are installed (CC / CXX to choose others) and linux/glibc_compat.c,
#   so that it runs on glibc 2.34 and later even when built on a newer system (Ubuntu 24.04: glibc 2.39, gcc 13 whose
#   static libstdc++ / libgcc would need glibc 2.36 / 2.35).
#   Machine code for sm_50 sm_52 sm_60 sm_61 sm_70 sm_75 sm_80 sm_86 sm_89 sm_90 sm_100 sm_120 + PTX compute_120.
#   Static CUDA runtime, static libstdc++ / libgcc: the binary only needs the NVIDIA driver (libcuda.so.1) and glibc.
#   Set GM_ARCHS to build fewer architectures, e.g. GM_ARCHS="-arch=sm_61".
#   Objects are kept in build/linux and rebuilt only when their source is newer, so the build can be resumed;
#   GM_ONE=1 compiles at most one CUDA object per run (environments that limit the length of one command).
#   The C references are built with -fno-strict-aliasing: Lyra2.c breaks the C aliasing rules and gcc -O2 then
#   computes a wrong lyra2rev2 (seen on 07/11/2026; the CPU reference check at start-up catches it).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dev/gostminer-linux}"
if [ -z "${CUDA_HOME:-}" ]; then
  if [ -x "$HOME/cuda/12.9/bin/nvcc" ]; then CUDA_HOME="$HOME/cuda/12.9"; else CUDA_HOME=/usr/local/cuda-12.9; fi
fi
NVCC="$CUDA_HOME/bin/nvcc"
ARCHS="${GM_ARCHS:--gencode arch=compute_50,code=sm_50 -gencode arch=compute_52,code=sm_52 -gencode arch=compute_60,code=sm_60 -gencode arch=compute_61,code=sm_61 -gencode arch=compute_70,code=sm_70 -gencode arch=compute_75,code=sm_75 -gencode arch=compute_80,code=sm_80 -gencode arch=compute_86,code=sm_86 -gencode arch=compute_89,code=sm_89 -gencode arch=compute_90,code=sm_90 -gencode arch=compute_100,code=sm_100 -gencode arch=compute_120,code=sm_120 -gencode arch=compute_120,code=compute_120}"
if [ -z "${CC:-}" ]; then if command -v gcc-11 >/dev/null; then CC=gcc-11; else CC=gcc; fi; fi
if [ -z "${CXX:-}" ]; then if command -v g++-11 >/dev/null; then CXX=g++-11; else CXX=g++; fi; fi
echo "host compilers: $CC / $CXX"
B=build/linux
mkdir -p "$(dirname "$OUT")" "$B"
"$NVCC" --version | tail -1
CSRC="linux/glibc_compat.c src/ethash_ref.c src/neoscrypt/neoscrypt.c src/gost_ref.c src/sha256.c src/lyra2ref/lyra2re2_only.c src/lyra2ref/Lyra2.c src/lyra2ref/Sponge.c src/lyra2ref/sha3/sph_blake.c src/lyra2ref/sha3/sph_keccak.c src/lyra2ref/sha3/sph_cubehash.c src/lyra2ref/sha3/sph_skein.c src/lyra2ref/sha3/sph_bmw.c"
CUSRC="gpu/gostminer.cu gpu/lyra2v2/lyra2v2_gpu.cu gpu/lyra2v2/ccminer_shim.cu gpu/lyra2v2/cuda_blake256.cu gpu/lyra2v2/cuda_bmw256.cu gpu/lyra2v2/cuda_cubehash256.cu gpu/lyra2v2/cuda_skein256.cu gpu/lyra2v2/cuda_lyra2v2.cu gpu/neoscrypt/neoscrypt_gpu.cu gpu/neoscrypt/cuda_neoscrypt.cu gpu/ting/ting_gpu.cu gpu/equihash192/eq_gpu.cu gpu/ethash/ethash_gpu.cu gpu/chc/chc_gpu.cu"
CXXSRC="gpu/equihash192/eq_host.cpp"
OBJS=""
for c in $CSRC; do
  o="$B/$(echo "$c" | tr '/' '_' | sed 's/\.c$/.o/')"
  if [ ! -f "$o" ] || [ "$c" -nt "$o" ]; then "$CC" -O2 -fno-strict-aliasing -c "$c" -Isrc -o "$o"; fi
  OBJS="$OBJS $o"
done
for c in $CXXSRC; do
  o="$B/$(echo "$c" | tr '/' '_' | sed 's/\.cpp$/.o/')"
  if [ ! -f "$o" ] || [ "$c" -nt "$o" ] || [ gpu/equihash192/eq_common.h -nt "$o" ]; then "$CXX" -O2 -std=c++17 -c "$c" -Isrc -Igpu -o "$o"; fi
  OBJS="$OBJS $o"
done
compiled=0
for c in $CUSRC; do
  o="$B/$(echo "$c" | tr '/' '_' | sed 's/\.cu$/.o/')"
  if [ ! -f "$o" ] || [ "$c" -nt "$o" ] || [ gpu/lyra2v2/cuda_helper.h -nt "$o" ]; then
    if [ "${GM_ONE:-0}" = "1" ] && [ $compiled -ge 1 ]; then echo "more objects to build: run again"; exit 0; fi
    echo "nvcc $c"
    "$NVCC" -ccbin "$CXX" -O3 --threads 0 $ARCHS -Wno-deprecated-gpu-targets -std=c++17 -Igpu -Isrc -Igpu/lyra2v2 \
      -Xcompiler "-O2 -pthread" -c "$c" -o "$o"
    compiled=$((compiled + 1))
  fi
  OBJS="$OBJS $o"
done
"$NVCC" -ccbin "$CXX" $ARCHS -Wno-deprecated-gpu-targets -cudart static -Xcompiler "-pthread -static-libstdc++ -static-libgcc" \
  -o "$OUT" $OBJS -lpthread -ldl -lrt
echo "built $OUT"
ls -l "$OUT"
echo "dynamic libraries:"; ldd "$OUT" || true
echo "highest glibc symbol version needed:"; objdump -T "$OUT" | grep -o 'GLIBC_[0-9.]*' | sort -V | tail -1
