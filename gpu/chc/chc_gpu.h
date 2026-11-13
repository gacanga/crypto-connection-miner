/* chc_gpu.h - Crypto Connection Miner: Chipcoin proof of work on NVIDIA GPUs (CHC; since 0.10.0).
 * Chipcoin (github.com/chipcoin-protocol/chipcoin, mainnet chipcoin-mainnet-1 since 07/11/2026), consensus/pow.py:
 *   hash = SHA-256(SHA-256(80-byte header)), header laid out like Bitcoin's (u32le version, previous hash, merkle
 *   root, u32le time, u32le bits, u32le nonce), BUT the digest is read as a BIG-endian integer (hashes.py
 *   hash_to_int): a block is valid when the FIRST bytes of the digest are zero (Bitcoin wants the last ones), which
 *   is why Bitcoin ASICs cannot mine it.
 * The first 64 header bytes are hashed once per job on the CPU (midstate), and so are the first 3 rounds of the
 * second block (words W0..W2 = merkle tail, time, bits). The GPU counter n is the big-endian word W3, i.e. the
 * header's nonce bytes are n big-endian and the nonce (u32le) is bswap32(n).
 * The GPU compares the top 64 bits of the digest (words H0, H1 of the second SHA-256) with the top 64 bits of the
 * target: every candidate is checked again on the CPU against the full 256-bit target. */
#ifndef GM_CHC_GPU_H
#define GM_CHC_GPU_H
#include <stdint.h>
#include <cuda_runtime.h>

#define CHC_MAX_RES 15

/* allocates the result buffer of device "dev" (current device must be "dev"); returns the grid size in *grid */
cudaError_t chc_init(int dev, int *grid);
void chc_free(int dev);
/* job: the 80-byte header (nonce ignored), top 64 bits of the big-endian target */
cudaError_t chc_set_job(int dev, const uint8_t header[80], uint64_t target64);
/* one launch: counters start + i, i < grid * 256 * npt; res[0] = number of candidates, res[1..] = their counters
 * (nonce = bswap32(counter)) */
cudaError_t chc_scan(int dev, uint32_t start, uint32_t npt, uint32_t res[1 + CHC_MAX_RES]);
#endif
