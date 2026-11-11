/* ethash_ref.c - Crypto Connection Miner: CPU reference of Ethash (since 0.9.0, NEX Chain). See ethash_ref.h.
 * Written for the miner from the Ethash specification (Ethereum yellow paper, appendix J; ethash wiki); checked at
 * start-up against real NEX Chain blocks (mix digest and result) and the cache / dataset sizes of the go-ethereum
 * tables. */
#include "ethash_ref.h"
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------- Keccak-f[1600] (original Keccak padding) */
static const uint64_t KRC[24] = {
	0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL, 0x8000000080008000ULL,
	0x000000000000808bULL, 0x0000000080000001ULL, 0x8000000080008081ULL, 0x8000000000008009ULL,
	0x000000000000008aULL, 0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
	0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL, 0x8000000000008003ULL,
	0x8000000000008002ULL, 0x8000000000000080ULL, 0x000000000000800aULL, 0x800000008000000aULL,
	0x8000000080008081ULL, 0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL};
static const int KROT[25] = {0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14};

static uint64_t rol64(uint64_t x, int n) { return n ? (x << n) | (x >> (64 - n)) : x; }

static void keccakf(uint64_t a[25])
{
	for (int r = 0; r < 24; r++) {
		uint64_t c[5], d[5], b[25];
		for (int x = 0; x < 5; x++) c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
		for (int x = 0; x < 5; x++) d[x] = c[(x + 4) % 5] ^ rol64(c[(x + 1) % 5], 1);
		for (int i = 0; i < 25; i++) a[i] ^= d[i % 5];
		/* rho and pi: b[y, 2x + 3y] = rot(a[x, y]) */
		for (int x = 0; x < 5; x++)
			for (int y = 0; y < 5; y++) b[y + 5 * ((2 * x + 3 * y) % 5)] = rol64(a[x + 5 * y], KROT[x + 5 * y]);
		for (int x = 0; x < 5; x++)
			for (int y = 0; y < 5; y++) a[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y]);
		a[0] ^= KRC[r];
	}
}

static uint64_t ld64(const uint8_t *p)
{
	uint64_t v = 0;
	for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
	return v;
}

static void st64(uint8_t *p, uint64_t v)
{
	for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static void keccak(const uint8_t *data, size_t len, uint8_t *out, size_t outlen)
{
	const size_t rate = 200 - 2 * outlen;
	uint64_t a[25];
	uint8_t blk[200];
	memset(a, 0, sizeof(a));
	while (len >= rate) {
		for (size_t i = 0; i < rate / 8; i++) a[i] ^= ld64(data + 8 * i);
		keccakf(a);
		data += rate;
		len -= rate;
	}
	memset(blk, 0, sizeof(blk));
	memcpy(blk, data, len);
	blk[len] ^= 0x01;
	blk[rate - 1] ^= 0x80;
	for (size_t i = 0; i < rate / 8; i++) a[i] ^= ld64(blk + 8 * i);
	keccakf(a);
	for (size_t i = 0; i < outlen / 8; i++) st64(out + 8 * i, a[i]);
}

void ethash_keccak256(const uint8_t *data, size_t len, uint8_t out[32]) { keccak(data, len, out, 32); }
void ethash_keccak512(const uint8_t *data, size_t len, uint8_t out[64]) { keccak(data, len, out, 64); }

/* ---------------------------------------------------------------- sizes and seed */
static int is_prime(uint64_t x)
{
	if (x < 2) return 0;
	if (x % 2 == 0) return x == 2;
	for (uint64_t i = 3; i * i <= x; i += 2)
		if (x % i == 0) return 0;
	return 1;
}

uint64_t ethash_cache_size(uint32_t epoch)
{
	uint64_t sz = (1ULL << 24) + (1ULL << 17) * epoch - 64;
	while (!is_prime(sz / 64)) sz -= 128;
	return sz;
}

uint64_t ethash_dataset_size(uint32_t epoch)
{
	uint64_t sz = (1ULL << 30) + (1ULL << 23) * epoch - 128;
	while (!is_prime(sz / 128)) sz -= 256;
	return sz;
}

void ethash_seed(uint32_t epoch, uint8_t seed[32])
{
	memset(seed, 0, 32);
	for (uint32_t i = 0; i < epoch; i++) ethash_keccak256(seed, 32, seed);
}

int ethash_epoch_of_seed(const uint8_t seed[32])
{
	uint8_t s[32];
	memset(s, 0, 32);
	for (uint32_t e = 0; e < ETHASH_MAX_EPOCH; e++) {
		if (memcmp(s, seed, 32) == 0) return (int)e;
		ethash_keccak256(s, 32, s);
	}
	return -1;
}

/* ---------------------------------------------------------------- cache, dataset items, hashimoto */
#define FNV_PRIME 0x01000193u
static uint32_t fnv(uint32_t a, uint32_t b) { return a * FNV_PRIME ^ b; }

static uint32_t ld32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static void st32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }

uint8_t *ethash_make_cache(uint32_t epoch)
{
	const uint64_t size = ethash_cache_size(epoch);
	const uint32_t n = (uint32_t)(size / 64);
	uint8_t *c = (uint8_t *)malloc((size_t)size);
	if (!c) return NULL;
	uint8_t seed[32], tmp[64];
	ethash_seed(epoch, seed);
	ethash_keccak512(seed, 32, c);
	for (uint32_t i = 1; i < n; i++) ethash_keccak512(c + 64 * (size_t)(i - 1), 64, c + 64 * (size_t)i);
	for (int round = 0; round < 3; round++) {
		for (uint32_t i = 0; i < n; i++) {
			const uint32_t v = ld32(c + 64 * (size_t)i) % n;
			const uint8_t *a = c + 64 * (size_t)((i + n - 1) % n);
			const uint8_t *b = c + 64 * (size_t)v;
			for (int k = 0; k < 64; k++) tmp[k] = a[k] ^ b[k];
			ethash_keccak512(tmp, 64, c + 64 * (size_t)i);
		}
	}
	return c;
}

void ethash_dataset_item(const uint8_t *cache, uint64_t cache_bytes, uint32_t index, uint8_t out[64])
{
	const uint32_t n = (uint32_t)(cache_bytes / 64);
	uint8_t m[64];
	uint32_t mix[16];
	memcpy(m, cache + 64 * (size_t)(index % n), 64);
	st32(m, ld32(m) ^ index);
	ethash_keccak512(m, 64, m);
	for (int k = 0; k < 16; k++) mix[k] = ld32(m + 4 * k);
	for (uint32_t j = 0; j < 256; j++) {
		const uint32_t parent = fnv(index ^ j, mix[j % 16]) % n;
		const uint8_t *p = cache + 64 * (size_t)parent;
		for (int k = 0; k < 16; k++) mix[k] = fnv(mix[k], ld32(p + 4 * k));
	}
	for (int k = 0; k < 16; k++) st32(m + 4 * k, mix[k]);
	ethash_keccak512(m, 64, out);
}

void ethash_light(const uint8_t *cache, uint64_t cache_bytes, uint64_t dataset_bytes, const uint8_t header[32],
                  uint64_t nonce, uint8_t mixout[32], uint8_t result[32])
{
	const uint32_t pages = (uint32_t)(dataset_bytes / 128);
	uint8_t hn[40], s[64], item[64], fin[96];
	uint32_t mix[32], s0;
	memcpy(hn, header, 32);
	st64(hn + 32, nonce);
	ethash_keccak512(hn, 40, s);
	s0 = ld32(s);
	for (int k = 0; k < 32; k++) mix[k] = ld32(s + 4 * (k % 16));
	for (uint32_t i = 0; i < 64; i++) {
		const uint32_t p = fnv(i ^ s0, mix[i % 32]) % pages;
		for (int h = 0; h < 2; h++) {
			ethash_dataset_item(cache, cache_bytes, 2 * p + h, item);
			for (int k = 0; k < 16; k++) mix[16 * h + k] = fnv(mix[16 * h + k], ld32(item + 4 * k));
		}
	}
	memcpy(fin, s, 64);
	for (int k = 0; k < 8; k++) {
		const uint32_t c = fnv(fnv(fnv(mix[4 * k], mix[4 * k + 1]), mix[4 * k + 2]), mix[4 * k + 3]);
		st32(fin + 64 + 4 * k, c);
	}
	memcpy(mixout, fin + 64, 32);
	ethash_keccak256(fin, 96, result);
}
