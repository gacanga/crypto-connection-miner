# Crypto Connection Miner

Free, open-source multi-coin GPU miner for NVIDIA cards, made for the [Crypto Connection](https://crypto-connection.net)
pool. **No dev fee.** (Named GostMiner up to version 0.4.0: https://github.com/gacanga/GostMiner.)

| Algorithm | Option | Coins | Crypto Connection port |
|---|---|---|---|
| gostd (GOST R 34.11-2012 "Streebog", chained) | `--algo gostd` (default) | GOSTcoin (GST) | 4033 |
| Lyra2REv2 | `--algo lyra2v2` | Bitmark (MARKS) and other Lyra2REv2 coins | 4043 |
| NeoScrypt | `--algo neoscrypt` | Feathercoin (FTC) and other NeoScrypt coins | 4063 |
| Ting (SHA-256 over Ting's tagged header) | `--algo ting` | Daler (DLR) and other coins of Ting | 4073 |
| Equihash 192,7 ("ZcashPoW") | `--algo equihash192` | Ycash (YEC) | 4053 |

- NVIDIA GPUs from Maxwell (GTX 900) to Blackwell (RTX 50), Windows 10/11 x64 and Linux x86-64 (glibc 2.34+).
  equihash192 needs about 5.4 GB of GPU memory per card (6 GB cards or more).
- Mines on the Crypto Connection pool by default; any stratum pool of these coins works with `--pool` (Ting: a pool
  that speaks the stratum described below). Solo mining on a local GOSTcoin wallet (getwork) as well.
- Every share found on the GPU is checked again on the CPU before it is sent; the CPU references are checked against
  real blocks at start-up.

Français : [README.fr.md](README.fr.md).

## Download

Binaries are on the [Releases](https://github.com/gacanga/crypto-connection-miner/releases) page, with their SHA-256.
The same files are on the [downloads page](https://crypto-connection.net/#/downloads) of the pool.

| File | SHA-256 |
|---|---|
| CryptoConnectionMiner-v0.8.0-win64-cuda12.zip | `bc939f2f8f3d8feec027f95144fddc64a0c1ac83e6d80c2992e4fa71402ba6e4` |
| CryptoConnectionMiner-v0.8.0-linux-x64-cuda12.tar.gz | `d4e954063e83f1cc6f3fc43f8e831a0fa4fa8a6689124d60c31f2993e5ff8afa` |

Check a file before you run it: Windows (PowerShell) `Get-FileHash FILE -Algorithm SHA256`, Linux `sha256sum FILE`.

## Quick start

Easiest: open `start_gostcoin.bat` / `start_gostcoin.sh` (GOSTcoin), `start_bitmark.bat` / `start_bitmark.sh`
(Bitmark), `start_feathercoin.bat` / `start_feathercoin.sh` (Feathercoin), `start_daler.bat` / `start_daler.sh`
(Daler: put your Ting account in `ACCOUNT`) or `start_ycash.bat` / `start_ycash.sh` (Ycash: a transparent address,
s1...), put your address in `ADDRESS`, then run it. It mines on the Crypto
Connection pool and restarts the miner automatically. Follow your hashrate, balance and payments on https://crypto-connection.net (My stats).

Command line: with `--user` and no `--pool`, the miner connects to the Crypto Connection pool
(crypto-connection.net, port 4033 for GOSTcoin, 4043 for Bitmark, 4063 for Feathercoin, 4073 for Daler, 4053 for Ycash).

```
GOSTcoin, Windows:  crypto-connection-miner.exe --user YOUR_GST_ADDRESS.rig1
GOSTcoin, Linux:    ./crypto-connection-miner --user YOUR_GST_ADDRESS.rig1
Bitmark,  Windows:  crypto-connection-miner.exe --algo lyra2v2 --user YOUR_MARKS_ADDRESS.rig1
Bitmark,  Linux:    ./crypto-connection-miner --algo lyra2v2 --user YOUR_MARKS_ADDRESS.rig1
Feathercoin, Windows: crypto-connection-miner.exe --algo neoscrypt --user YOUR_FTC_ADDRESS.rig1
Feathercoin, Linux:   ./crypto-connection-miner --algo neoscrypt --user YOUR_FTC_ADDRESS.rig1
Daler, Windows:     crypto-connection-miner.exe --algo ting --user YOUR_TING_ACCOUNT.rig1
Daler, Linux:       ./crypto-connection-miner --algo ting --user YOUR_TING_ACCOUNT.rig1
Ycash, Windows:     crypto-connection-miner.exe --algo equihash192 --user YOUR_YEC_ADDRESS.rig1
Ycash, Linux:       ./crypto-connection-miner --algo equihash192 --user YOUR_YEC_ADDRESS.rig1
Another pool:       crypto-connection-miner.exe --pool HOST:PORT --user YOUR_ADDRESS.rig1 --pass x
```

`test.bat` / `test.sh` check every GPU against the five algorithms.

A Ting account (Daler payouts) is 64 hex characters: create one with the Ting ID Android app
(https://github.com/ting-organization/ting-id) or with `ting wallet create` of ting-miner
(https://github.com/ting-organization/ting-miner).

Ycash payouts go to a transparent address (s1...): YecWallet or ycashd (https://github.com/ycashfoundation).

## Options

| Option | Meaning |
|---|---|
| `--algo A` | `gostd` (GOSTcoin, default), `lyra2v2` (Bitmark), `neoscrypt` (Feathercoin), `ting` (Daler) or `equihash192` (Ycash) |
| `--pool HOST:PORT` | stratum pool (default with `--user`: crypto-connection.net, port 4033 gostd / 4043 lyra2v2 / 4063 neoscrypt / 4073 ting / 4053 equihash192) |
| `--user ADDRESS.WORKER --pass x` | your payout address and a worker name; `--pass d=64` asks the pool for a fixed difficulty |
| `--gpus 0,1,2` | GPUs to use (default: all) |
| `--kernel N` | gostd: force a kernel variant (default: each GPU measures the 5 variants for 3 s and keeps the fastest) |
| `--intensity N` | lyra2v2: 2^N hashes per launch (default 22 on GPUs up to 20 SM, 23-24 on larger ones, limited by the GPU memory); neoscrypt: 2^N hashes per launch (default 16 up to 20 SM, 17-18 on larger ones, about 33 KB of GPU memory per hash) |
| `--tpb N` | equihash192: threads per block of the collision kernels (multiple of 32, default 512) |
| `--stats S` | statistics every S seconds (default 30) |
| `--log FILE` | also write the log to FILE |
| `--selftest` | check every GPU against the coin's consensus hash and exit |
| `--bench S` | hash for S seconds without a pool |
| `--conf gostcoin.conf --port 8795` | solo on a local GOSTcoin wallet (getwork, gostd) |

## Checks

At start-up the miner checks its CPU references against real blocks: GOSTcoin genesis block, a coinbase transaction id
and a merkle root; Bitmark block 2490869 hash, its lyra2rev2 proof of work and merkle root; Feathercoin block
6428900 hash and its NeoScrypt proof of work; the BlockId of Ting block 35104; for Ycash, BLAKE2b "ZcashPoW" known
answers and 6 real Ycash blocks (mined solution valid, block hash recomputed, altered solutions rejected). If it prints
`WRONG`, do not mine. The lyra2v2 GPU self test must find the nonce of Bitmark block 2490869, the neoscrypt one the
nonce of Feathercoin block 6428900, the ting one the nonce of Ting block 35104, the equihash192 one exactly the
reference solutions of 5 headers (3 of a real pool job, 2 real Ycash blocks whose mined solution must be found).

## CUDA errors and overclocking

If a GPU reports a CUDA error, the miner writes the last pool messages to the log and exits with code 3; the start
scripts restart it after 5 s (a clean restart is the safe way to recover a GPU).

The gostd kernel loads the GPU core harder than older gostd miners. On P104-100 / GTX 10xx cards a core overclock
(+100 or +200 MHz) caused "illegal memory access" errors in our tests; with the core at stock clock there was none.
Keep the core at stock (a memory offset and a power limit are fine) and lower it if the error appears.

Typical speed on a P104-100 (GTX 1070 class) at 160 W, core at stock: gostd 21-23 MH/s, lyra2v2 36-37 MH/s,
neoscrypt about 865 kH/s (the miner shows neoscrypt speeds in kH/s), ting about 2.05-2.09 GH/s (shown as 2050-2090 MH/s),
equihash192 about 11-15 Sol/s depending on the memory clock (valid solutions per
second).

## Ting stratum (Daler)

Ting has no stratum protocol of its own; the Crypto Connection pool (Miningcore, family `ting`) speaks this one:

- `mining.subscribe` -> `[[...], EXTRANONCE1 (8 hex = 4 bytes), 12]`
- `mining.authorize` `["ACCOUNT.worker", "x"]` - ACCOUNT is a Ting account, 64 hex characters
- `mining.set_difficulty` `[d]` - share target = 2^224 / d (difficulty 1 = about 2^32 hashes)
- `mining.notify` `[job id, HEADER (the 278 bytes of the header before the nonce, hex), height, network target (64 hex,
  big-endian), clean]`
- `mining.submit` `["ACCOUNT.worker", job id, NONCE (32 hex = the 16 nonce bytes as they go in the header, a
  little-endian u128; bytes 12-15 = EXTRANONCE1)]`

A share: SHA-256(`"Ting/"` 05 00 `"block"` || HEADER || NONCE), read as a big-endian integer, <= the share target
(it is the BlockId of Ting's protocol rules, section 8.1). The miner hashes the first four SHA-256 blocks and the
first 8 rounds of the last one once per job: one attempt costs 56 rounds of one compression.

## Equihash 192,7 (Ycash)

One run of the solver = one nonce: 2^24 BLAKE2b-384 hashes (personalization "ZcashPoW" || 192 || 7) give 2^25 strings
of 24 bytes, then 6 collision steps on 24-bit digits and a final one on 48 bits (Wagner's algorithm, 4096 buckets,
linked lists in shared memory), then the 128 indices of each candidate are rebuilt. The solver is the one of
[YecMiner](https://github.com/gacanga/YecMiner)
(same author, Apache-2.0, `gpu/equihash192`). Every candidate is put in canonical order and validated on the CPU
(collisions, order, distinct indices) before its block hash, SHA256d(header || fd9001 || solution), is compared with
the share target.

Stratum (Zcash style, as Miningcore and NOMP): `mining.subscribe` -> `[session, EXTRANONCE1]`; `mining.set_target`
`[64 hex, big-endian]` (used as is; `mining.set_difficulty` alone: target = 0x0007ffff..ff / d); `mining.notify`
`[job, version, previous hash, merkle root, reserved, time, bits, clean]` (header fields in header byte order); the
32-byte nonce is EXTRANONCE1 || EXTRANONCE2 (GPU slot, session, counter); `mining.submit` `[worker, job, time,
EXTRANONCE2, "fd9001" + solution]`.

## Build

- Windows: CUDA 12.9 and Visual Studio 2022 (C++ tools), then `windows\build_miner.bat dev\crypto-connection-miner.exe`.
- Linux: CUDA 12.9 (`CUDA_HOME`) and gcc / g++ 11 or later, then `linux/build_linux.sh dev/crypto-connection-miner`.
- Machine code for every GPU generation CUDA 12.9 targets (sm_50 to sm_120) plus PTX; set `GM_ARCHS` to build fewer,
  e.g. `GM_ARCHS=-arch=sm_61`.
- The C references must be built with `-fno-strict-aliasing`: Lyra2.c breaks the C aliasing rules and gcc -O2 would
  otherwise compute a wrong lyra2rev2 (the start-up check catches it).
- The start scripts of the packages are in `dist/`.

## Changes

- 0.8.0: new algorithm `--algo equihash192` for Ycash (YEC): Equihash 192,7 "ZcashPoW" with the solver of YecMiner
  (Apache-2.0), about 11-15 Sol/s on a P104-100, about 5.4 GB of GPU memory per card; Zcash-style stratum (above);
  pool port 4053 by default; option `--tpb`; start scripts `start_ycash`; `test` checks the five algorithms; CPU
  checks on 6 real Ycash blocks and GPU self test on 5 reference headers. gostd, lyra2v2, neoscrypt and ting unchanged.
- 0.7.0: new algorithm `--algo ting` for Daler (DLR) on Ting: one SHA-256 compression per attempt from a midstate
  (first four blocks and first 8 rounds of the last one hashed once per job, message schedule words 16-23 partly
  precomputed), about 2.05-2.09 GH/s on a P104-100; Crypto Connection stratum for Ting (above); pool port 4073 by
  default; start scripts `start_daler`; `test` checks the four algorithms; CPU and GPU self tests on Ting block 35104.
  gostd, lyra2v2 and neoscrypt unchanged.
- 0.6.0: new algorithm `--algo neoscrypt` for Feathercoin (FTC) and other NeoScrypt coins, with the NeoScrypt
  kernels of ccminer 2.3.1 (about 865 kH/s on a P104-100, same as ccminer) and a CPU check of every share; pool
  port 4063 by default; start scripts `start_feathercoin`; `test` checks the three algorithms; CPU and GPU self tests
  on Feathercoin block 6428900. gostd and lyra2v2 unchanged.
- 0.5.0: renamed Crypto Connection Miner (binary `crypto-connection-miner`); `--user` without `--pool` mines on the
  Crypto Connection pool; start scripts `start_gostcoin` / `start_bitmark` set to crypto-connection.net (4033 / 4043).
  Mining code unchanged from GostMiner 0.4.0.

## Licence

GNU GPL v3 (`LICENSE`, `COPYING.txt`): the lyra2v2 and neoscrypt GPU kernels come from ccminer 2.3.1; the ting kernel
(`gpu/ting`) was written for this miner; the equihash192 solver (`gpu/equihash192`) comes from YecMiner, same
author, Apache-2.0 (compatible with the GPL v3). Third-party code and its licences are listed in `NOTICE.txt`.
