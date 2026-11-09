/* neoscrypt_gpu.h - Crypto Connection Miner driver of the ccminer NeoScrypt CUDA kernels of this folder (GPL-3, see
 * gpu/lyra2v2/COPYING-ccminer-GPL3.txt). NeoScrypt (Feathercoin and others): FastKDF(BLAKE2s) > Salsa20/20 and
 * ChaCha20/20 (N = 128, r = 2) > FastKDF; 32 KB of GPU memory per hash in flight.
 * Nonce convention: the GPU puts the counter n in header bytes 76..79 little-endian, so the header nonce (as sent to
 * the pool) is n itself. Only the top 32 bits of the hash are compared on the GPU: every candidate is checked on the
 * CPU against the full target. */
#ifndef GM_NEOSCRYPT_GPU_H
#define GM_NEOSCRYPT_GPU_H
#include <stdint.h>
#include <cuda_runtime.h>

/* GPU memory needed per hash of a launch, in bytes */
#define NS_BYTES_PER_HASH (32u * 128u * 8u + 3u * 32u * 8u + 64u)

/* allocates the buffers of device "dev" (current device must be "dev"); throughput = hashes per launch (multiple of 64) */
cudaError_t ns_init(int dev, uint32_t throughput);
void ns_free(int dev);
uint32_t ns_throughput(int dev);
/* job: 80-byte header (nonce bytes ignored) and the 256-bit little-endian target (target[31] most significant) */
cudaError_t ns_set_job(int dev, const uint8_t header[80], const uint8_t target_le[32]);
/* one launch over nonces start .. start + throughput - 1; *hit = a candidate was found, *nonce = its header nonce */
cudaError_t ns_scan(int dev, uint32_t start, uint32_t *nonce, bool *hit);
#endif
