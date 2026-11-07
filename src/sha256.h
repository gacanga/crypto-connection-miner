/* sha256.h - SHA-256 and double SHA-256 (Bitcoin family transaction ids and merkle nodes) for Crypto Connection Miner. */
#ifndef GM_SHA256_H
#define GM_SHA256_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void gm_sha256(const uint8_t *data, size_t len, uint8_t out[32]);
void gm_sha256d(const uint8_t *data, size_t len, uint8_t out[32]);
#ifdef __cplusplus
}
#endif
#endif
