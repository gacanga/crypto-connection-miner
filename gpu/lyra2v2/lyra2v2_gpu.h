/* lyra2v2_gpu.h - Crypto Connection Miner driver of the ccminer lyra2v2 (Lyra2REv2) CUDA pipeline (GPL-3, see COPYING-ccminer-GPL3.txt).
 * Pipeline per launch: blake256+keccak256 (80-byte header) -> cubehash256 -> Lyra2(1,4,4) -> skein256 -> cubehash256
 * -> bmw256 + target test on the top 64 bits. Nonce convention of ccminer: the GPU puts the counter n in header bytes
 * 76..79 BIG-endian, so the header nonce (little-endian uint32, as sent to the pool) is bswap32(n). */
#ifndef GM_LYRA2V2_GPU_H
#define GM_LYRA2V2_GPU_H
#include <stdint.h>
#include <cuda_runtime.h>

/* allocates the buffers of device "dev" (current device must be "dev"); throughput = hashes per launch */
cudaError_t l2_init(int dev, uint32_t throughput);
void l2_free(int dev);
uint32_t l2_throughput(int dev);
/* job: 80-byte header (nonce bytes ignored) and the 256-bit little-endian target (target[31] most significant) */
cudaError_t l2_set_job(int dev, const uint8_t header[80], const uint8_t target_le[32]);
/* one launch over counters start .. start + throughput - 1; up to 2 candidate counters (0 = none) */
cudaError_t l2_scan(int dev, uint32_t start, uint32_t found[2]);
#endif
