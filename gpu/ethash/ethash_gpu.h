/* ethash_gpu.h - Crypto Connection Miner: Ethash on NVIDIA GPUs (NEX Chain, NEXC; since 0.9.0).
 * The dataset (DAG, about 1 GB at epoch 1, +8 MB every 30000 blocks) is generated on the GPU from the cache that the
 * host builds (src/ethash_ref.c); then each nonce costs one keccak512, 64 accesses to random 128-byte pages of the DAG
 * and one keccak256. The search kernel lets 8 threads work on one hash at a time (each thread loads 16 bytes of every
 * 128-byte page, so a page is one coalesced load), as the ethminer CUDA kernel does; written for this miner.
 * The GPU compares the top 64 bits of the result (big-endian) with the top 64 bits of the target: every candidate is
 * checked on the CPU (light evaluation from the cache) against the full 256-bit target. */
#ifndef GM_ETHASH_GPU_H
#define GM_ETHASH_GPU_H
#include <stdint.h>
#include <cuda_runtime.h>

#define ETH_MAX_RES 15
#define ETH_TPB 128          /* threads per block of the search kernel (multiple of 8) */

/* allocates the result buffer of device "dev" (current device must be "dev"); returns the default number of
 * nonces per launch in *batch (a multiple of ETH_TPB) */
cudaError_t eth_init(int dev, uint32_t *batch);
void eth_free(int dev);
/* (re)builds the DAG of an epoch on the GPU from its cache (cache_bytes = cache size, dag_bytes = dataset size);
 * keeps the DAG when it is already the one of this epoch. progress(percent) is called from the calling thread. */
cudaError_t eth_make_dag(int dev, uint32_t epoch, const uint8_t *cache, uint64_t cache_bytes, uint64_t dag_bytes,
                         void (*progress)(int dev, int percent));
/* epoch of the DAG on the GPU, -1 if none */
int eth_dag_epoch(int dev);
/* job: header hash (32 bytes) and top 64 bits of the big-endian share target */
cudaError_t eth_set_job(int dev, const uint8_t header[32], uint64_t target64);
/* one launch: nonces start .. start + count - 1 (count a multiple of ETH_TPB); res[0] = number of candidates,
 * res[1..] = their nonces */
cudaError_t eth_scan(int dev, uint64_t start, uint32_t count, uint64_t res[1 + ETH_MAX_RES]);
#endif
