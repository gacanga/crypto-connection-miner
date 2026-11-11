/* ethash_ref.h - Crypto Connection Miner: CPU reference of Ethash (since 0.9.0, NEX Chain).
 * Ethash as specified in the Ethereum yellow paper (appendix J) and implemented by go-ethereum / core-geth:
 *   - epoch = block / 30000; cache and dataset sizes = the largest sizes below 2^24 + 2^17 * epoch - 64 bytes and
 *     2^30 + 2^23 * epoch - 128 bytes whose number of 64-byte (cache) / 128-byte (dataset) rows is prime;
 *   - seed = keccak256 applied "epoch" times to 32 zero bytes;
 *   - cache: keccak512 chain from the seed, then 3 rounds of RandMemoHash;
 *   - dataset item i: keccak512 of the cache row i mixed with 256 parent rows (FNV), then keccak512 again;
 *   - hashimoto: s = keccak512(header hash || nonce, little-endian), 64 FNV accesses to 128-byte dataset pages,
 *     compressed mix (32 bytes) and result = keccak256(s || compressed mix).
 * keccak is the original Keccak (padding byte 0x01), as Ethereum uses it.
 * The miner uses it to check every GPU candidate (light evaluation from the cache, no dataset on the CPU) and in its
 * start-up self tests against real NEX Chain blocks. */
#ifndef GM_ETHASH_REF_H
#define GM_ETHASH_REF_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ETHASH_EPOCH_LENGTH 30000u
#define ETHASH_MAX_EPOCH 2048u

void ethash_keccak256(const uint8_t *data, size_t len, uint8_t out[32]);
void ethash_keccak512(const uint8_t *data, size_t len, uint8_t out[64]);

uint64_t ethash_cache_size(uint32_t epoch);     /* bytes */
uint64_t ethash_dataset_size(uint32_t epoch);   /* bytes */
void ethash_seed(uint32_t epoch, uint8_t seed[32]);
/* epoch whose seed is "seed" (searched up to ETHASH_MAX_EPOCH), -1 if none */
int ethash_epoch_of_seed(const uint8_t seed[32]);

/* the cache of an epoch: cache_size(epoch) bytes, allocated with malloc (free with free), NULL on failure */
uint8_t *ethash_make_cache(uint32_t epoch);

/* one 64-byte dataset item computed from the cache (cache_bytes = cache_size of the epoch) */
void ethash_dataset_item(const uint8_t *cache, uint64_t cache_bytes, uint32_t index, uint8_t out[64]);

/* light hashimoto: header hash (32 bytes), nonce, dataset size of the epoch; mix digest (32) and result (32 bytes,
 * compared with the target as a big-endian number) */
void ethash_light(const uint8_t *cache, uint64_t cache_bytes, uint64_t dataset_bytes, const uint8_t header[32],
                  uint64_t nonce, uint8_t mix[32], uint8_t result[32]);

#ifdef __cplusplus
}
#endif
#endif
