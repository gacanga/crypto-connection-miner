# Crypto Connection Miner

Free, open-source multi-coin GPU miner for NVIDIA cards, made for the [Crypto Connection](https://crypto-connection.net)
pool. **No dev fee.** (Named GostMiner up to version 0.4.0: https://github.com/gacanga/GostMiner.)

| Algorithm | Option | Coins | Crypto Connection port |
|---|---|---|---|
| gostd (GOST R 34.11-2012 "Streebog", chained) | `--algo gostd` (default) | GOSTcoin (GST) | 4033 |
| Lyra2REv2 | `--algo lyra2v2` | Bitmark (MARKS) and other Lyra2REv2 coins | 4043 |

- NVIDIA GPUs from Maxwell (GTX 900) to Blackwell (RTX 50), Windows 10/11 x64 and Linux x86-64 (glibc 2.34+).
- Mines on the Crypto Connection pool by default; any stratum pool of these coins works with `--pool`. Solo mining on
  a local GOSTcoin wallet (getwork) as well.
- Every share found on the GPU is checked again on the CPU before it is sent; the CPU references are checked against
  real blocks at start-up.

Français : [README.fr.md](README.fr.md).

## Download

Binaries are on the [Releases](https://github.com/gacanga/crypto-connection-miner/releases) page, with their SHA-256.
The same files are on the [downloads page](https://crypto-connection.net/#/downloads) of the pool.

| File | SHA-256 |
|---|---|
| CryptoConnectionMiner-v0.5.0-win64-cuda12.zip | `7513de4cbf87eee4c696ccb72f83d552c260dd3a5e4fad1e41dcd2962837c857` |
| CryptoConnectionMiner-v0.5.0-linux-x64-cuda12.tar.gz | `7ab4c079c787e7a3a04a1c26af141616d3fefcbe0df9c6d8f73727f173ea0198` |

Check a file before you run it: Windows (PowerShell) `Get-FileHash FILE -Algorithm SHA256`, Linux `sha256sum FILE`.

## Quick start

Easiest: open `start_gostcoin.bat` / `start_gostcoin.sh` (GOSTcoin) or `start_bitmark.bat` / `start_bitmark.sh`
(Bitmark), put your address in `ADDRESS`, then run it. It mines on the Crypto Connection pool and restarts the miner
automatically. Follow your hashrate, balance and payments on https://crypto-connection.net (My stats).

Command line: with `--user` and no `--pool`, the miner connects to the Crypto Connection pool
(crypto-connection.net, port 4033 for GOSTcoin, 4043 for Bitmark).

```
GOSTcoin, Windows:  crypto-connection-miner.exe --user YOUR_GST_ADDRESS.rig1
GOSTcoin, Linux:    ./crypto-connection-miner --user YOUR_GST_ADDRESS.rig1
Bitmark,  Windows:  crypto-connection-miner.exe --algo lyra2v2 --user YOUR_MARKS_ADDRESS.rig1
Bitmark,  Linux:    ./crypto-connection-miner --algo lyra2v2 --user YOUR_MARKS_ADDRESS.rig1
Another pool:       crypto-connection-miner.exe --pool HOST:PORT --user YOUR_ADDRESS.rig1 --pass x
```

`test.bat` / `test.sh` check every GPU against both algorithms.

## Options

| Option | Meaning |
|---|---|
| `--algo A` | `gostd` (GOSTcoin, default) or `lyra2v2` (Bitmark) |
| `--pool HOST:PORT` | stratum pool (default with `--user`: crypto-connection.net, port 4033 gostd / 4043 lyra2v2) |
| `--user ADDRESS.WORKER --pass x` | your payout address and a worker name; `--pass d=64` asks the pool for a fixed difficulty |
| `--gpus 0,1,2` | GPUs to use (default: all) |
| `--kernel N` | gostd: force a kernel variant (default: each GPU measures the 5 variants for 3 s and keeps the fastest) |
| `--intensity N` | lyra2v2: 2^N hashes per launch (default 22 on GPUs up to 20 SM, 23-24 on larger ones, limited by the GPU memory) |
| `--stats S` | statistics every S seconds (default 30) |
| `--log FILE` | also write the log to FILE |
| `--selftest` | check every GPU against the coin's consensus hash and exit |
| `--bench S` | hash for S seconds without a pool |
| `--conf gostcoin.conf --port 8795` | solo on a local GOSTcoin wallet (getwork, gostd) |

## Checks

At start-up the miner checks its CPU references against real blocks: GOSTcoin genesis block, a coinbase transaction id
and a merkle root; Bitmark block 2490869 hash, its lyra2rev2 proof of work and merkle root. If it prints `WRONG`, do
not mine. The lyra2v2 GPU self test must find the nonce of Bitmark block 2490869.

## CUDA errors and overclocking

If a GPU reports a CUDA error, the miner writes the last pool messages to the log and exits with code 3; the start
scripts restart it after 5 s (a clean restart is the safe way to recover a GPU).

The gostd kernel loads the GPU core harder than older gostd miners. On P104-100 / GTX 10xx cards a core overclock
(+100 or +200 MHz) caused "illegal memory access" errors in our tests; with the core at stock clock there was none.
Keep the core at stock (a memory offset and a power limit are fine) and lower it if the error appears.

Typical speed on a P104-100 (GTX 1070 class) at 160 W, core at stock: gostd 21-23 MH/s, lyra2v2 36-37 MH/s.

## Build

- Windows: CUDA 12.9 and Visual Studio 2022 (C++ tools), then `windows\build_miner.bat dev\crypto-connection-miner.exe`.
- Linux: CUDA 12.9 (`CUDA_HOME`) and gcc / g++ 11 or later, then `linux/build_linux.sh dev/crypto-connection-miner`.
- Machine code for every GPU generation CUDA 12.9 targets (sm_50 to sm_120) plus PTX; set `GM_ARCHS` to build fewer,
  e.g. `GM_ARCHS=-arch=sm_61`.
- The C references must be built with `-fno-strict-aliasing`: Lyra2.c breaks the C aliasing rules and gcc -O2 would
  otherwise compute a wrong lyra2rev2 (the start-up check catches it).
- The start scripts of the packages are in `dist/`.

## Changes

- 0.5.0: renamed Crypto Connection Miner (binary `crypto-connection-miner`); `--user` without `--pool` mines on the
  Crypto Connection pool; start scripts `start_gostcoin` / `start_bitmark` set to crypto-connection.net (4033 / 4043).
  Mining code unchanged from GostMiner 0.4.0.

## Licence

GNU GPL v3 (`LICENSE`, `COPYING.txt`): the lyra2v2 GPU kernels come from ccminer 2.3.1. Third-party code and its
licences are listed in `NOTICE.txt`.
