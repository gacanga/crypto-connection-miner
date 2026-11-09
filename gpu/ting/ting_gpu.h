/* ting_gpu.h - Crypto Connection Miner: Ting proof of work on NVIDIA GPUs (Daler, DLR; since 0.7.0).
 * Ting (github.com/ting-organization, mainnet 21/10/2026), protocol rules section 8.1:
 *   BlockId = SHA-256( "Ting/" || u16le(5) || "block" || header )   (12 + 294 = 306 bytes, 5 SHA-256 blocks)
 *   valid when the BlockId, read as a big-endian integer, is <= the header's target (big-endian u256).
 * The header's last 16 bytes (offset 278) are the nonce, a little-endian u128. They sit in the 5th SHA-256 block, so
 * the first 4 blocks are hashed once per job on the CPU (midstate) and so are the first 8 rounds of the 5th block,
 * whose words W0..W7 do not depend on the nonce: one attempt costs 56 rounds of one compression.
 * Nonce layout used by this miner: bytes 0..3 = the GPU counter (scanned 2^32 per work unit), bytes 4..11 = chosen by
 * the host per work unit (GPU slot + counter), bytes 12..15 = the pool's extranonce1 (Crypto Connection stratum).
 * The GPU compares the top 64 bits of the hash with the top 64 bits of the target: every candidate is checked on the
 * CPU against the full 256-bit target. */
#ifndef GM_TING_GPU_H
#define GM_TING_GPU_H
#include <stdint.h>
#include <cuda_runtime.h>

#define TING_HEADER_SIZE 294
#define TING_NONCE_OFFSET 278
#define TING_MAX_RES 15

/* the 306-byte message hashed for the BlockId: tag || header with NONCE (16 bytes) */
void ting_message(const uint8_t prefix[TING_NONCE_OFFSET], const uint8_t nonce[16], uint8_t msg[12 + TING_HEADER_SIZE]);
/* BlockId (big-endian hash bytes, as the node shows it) of a header prefix and a nonce, on the CPU */
void ting_block_id(const uint8_t prefix[TING_NONCE_OFFSET], const uint8_t nonce[16], uint8_t id[32]);

/* allocates the result buffer of device "dev" (current device must be "dev"); returns the grid size in *grid */
cudaError_t ting_init(int dev, int *grid);
void ting_free(int dev);
/* job: header prefix (278 bytes), nonce bytes 4..15, top 64 bits of the big-endian target */
cudaError_t ting_set_job(int dev, const uint8_t prefix[TING_NONCE_OFFSET], const uint8_t nonce_hi[12], uint64_t target64);
/* one launch: counters start + i, i < grid * 256 * npt; res[0] = number of candidates, res[1..] = their counters
 * (nonce bytes 0..3, little-endian) */
cudaError_t ting_scan(int dev, uint32_t start, uint32_t npt, uint32_t res[1 + TING_MAX_RES]);
#endif
