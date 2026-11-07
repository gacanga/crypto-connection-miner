/*
 * gostd_core.h - GOSTcoin proof of work (gostd) for Crypto Connection Miner, shared by the CPU (g++/MSVC) and the GPU (nvcc).
 *
 *   gostd(header) = GOST R 34.11-2012-256( GOST R 34.11-2012-512( 80-byte header ) )
 *
 * Representation: the 64-byte Streebog states are the byte arrays of the GOSTcoin reference code
 * (src/Gost.cpp, big-endian convention: byte 63 is the least significant byte), loaded as 8 little-endian
 * 64-bit words. One round function LPS is then out[j] = XOR_i T[i][ byte j of in[7-i] ].
 *
 * Work per nonce (LPS = 64 table lookups):
 *   hash-512 : 1st block (the 64 bytes that hold the nonce, h = 0, keys precomputed)  12 LPS
 *              2nd block (first 16 header bytes + padding, N = 512)                   25 LPS
 *              N = 640 and Sigma                                                      2 x 25 LPS
 *   hash-256 : 1st block (h = 0x01.., keys precomputed) 12 LPS, padding block 25 LPS, N = 512 25 LPS,
 *              Sigma: only the first 64-bit word of the digest is computed (22 LPS + 16 lookups)
 * Savings against the GOSTSec ccminer kernel: the first LPS of hash-512 is precomputed per job except the
 * 4 nonce bytes (4 lookups instead of 64), the last compression computes only the word compared with the
 * target, and the Sigma additions carry over the full 512 bits (the old kernel dropped some carries).
 * Register use: a compression keeps h ^ m instead of h and m, Sigma of hash-512 is rebuilt from the nonce
 * when needed, so a compression holds 4 states (h ^ m, s, t, k). The hash-512 digest (needed again for the
 * last Sigma of hash-256) is parked in a "stash": stash[i * stride], i = 0..7 (shared memory on the GPU,
 * a local array on the CPU).
 *
 * Table access goes through a "table bank" object TB with  uint64_t TB::t(int table, int outword, uint32_t idx)
 * so the GPU can choose, per (output word, table), shared memory or the read-only cache (__ldg).
 * GOST_RUNROLL (default 1) is the unroll factor of the 12-round loops on the GPU.
 */
#ifndef GOSTD_CORE_H
#define GOSTD_CORE_H

#include <stdint.h>
#include <stdlib.h>

#ifdef __CUDACC__
#define GH __host__ __device__
#define GD __host__ __device__ __forceinline__
#else
#define GH
#define GD static inline
#endif

#ifndef GOST_RUNROLL
#define GOST_RUNROLL 1
#endif

#define GOST_PRAGMA_(x) _Pragma(#x)
#define GOST_PRAGMA(x) GOST_PRAGMA_(x)
#ifdef __CUDA_ARCH__
#define GOST_UNROLL GOST_PRAGMA(unroll)
#define GOST_UNROLL_ROUNDS GOST_PRAGMA(unroll GOST_RUNROLL)
#else
#define GOST_UNROLL
#define GOST_UNROLL_ROUNDS
#endif

/* byte j (0 = least significant) of a 64-bit word */
GD uint32_t gost_byte(uint64_t x, int j)
{
#ifdef __CUDA_ARCH__
	const uint32_t half = (j < 4) ? (uint32_t)x : (uint32_t)(x >> 32);
	return __byte_perm(half, 0, 0x4440 + (j & 3));
#else
	return (uint32_t)(x >> (8 * j)) & 0xFF;
#endif
}

GD uint64_t gost_bswap64(uint64_t x)
{
#ifdef __CUDA_ARCH__
	const uint32_t lo = (uint32_t)x, hi = (uint32_t)(x >> 32);
	return ((uint64_t)__byte_perm(lo, 0, 0x0123) << 32) | __byte_perm(hi, 0, 0x0123);
#elif defined(_MSC_VER)
	return _byteswap_uint64(x);
#else
	return __builtin_bswap64(x);
#endif
}

/* constants of one job and of the algorithm (filled on the host by gostd_prepare_job) */
typedef struct {
	uint64_t m1[8];        /* header bytes 16..79 (word 7 high half = nonce, kept 0 here) */
	uint64_t m2[8];        /* padding block: header bytes 0..15 at bytes 48..63, 0x01 at byte 47 */
	uint64_t q[8];         /* first LPS of hash-512 without the 4 nonce bytes (words 0..3 are final) */
	uint64_t rka[13][8];   /* hash-512 1st block keys: K0 = LPS(0), K(i+1) = LPS(K(i) ^ C(i)) */
	uint64_t rkb[13][8];   /* hash-256 1st block keys: K0 = LPS(0x01..), same schedule */
	uint64_t c[12][8];     /* Streebog round constants */
	uint64_t target;       /* most significant 64 bits of the target (digest bytes 0..7, big-endian) */
} gostd_job_t;

#define GOST_N512 0x0002000000000000ULL   /* word 7 of N = 512 */
#define GOST_N640 0x8002000000000000ULL   /* word 7 of N = 640 */
#define GOST_IV1  0x0101010101010101ULL   /* hash-256 initial value */
#define GOST_PAD7 0x0100000000000000ULL   /* word 7 of the empty padding block (0x01 at byte 63) */

/* out = LPS(in) */
template <class TB>
GD void gost_lps(const TB &tb, const uint64_t in[8], uint64_t out[8])
{
	GOST_UNROLL
	for (int j = 0; j < 8; j++) {
		out[j] = tb.t(0, j, gost_byte(in[7], j)) ^ tb.t(1, j, gost_byte(in[6], j))
		       ^ tb.t(2, j, gost_byte(in[5], j)) ^ tb.t(3, j, gost_byte(in[4], j))
		       ^ tb.t(4, j, gost_byte(in[3], j)) ^ tb.t(5, j, gost_byte(in[2], j))
		       ^ tb.t(6, j, gost_byte(in[1], j)) ^ tb.t(7, j, gost_byte(in[0], j));
	}
}

/* word 0 of LPS(in) */
template <class TB>
GD uint64_t gost_lps_w0(const TB &tb, const uint64_t in[8])
{
	return tb.t(0, 0, gost_byte(in[7], 0)) ^ tb.t(1, 0, gost_byte(in[6], 0))
	     ^ tb.t(2, 0, gost_byte(in[5], 0)) ^ tb.t(3, 0, gost_byte(in[4], 0))
	     ^ tb.t(4, 0, gost_byte(in[3], 0)) ^ tb.t(5, 0, gost_byte(in[2], 0))
	     ^ tb.t(6, 0, gost_byte(in[1], 0)) ^ tb.t(7, 0, gost_byte(in[0], 0));
}

/* 12 rounds of E: s = state after the key addition, k = round key 0; returns the final state in s */
template <class TB>
GD void gost_e_rounds(const TB &tb, const uint64_t *c, uint64_t s[8], uint64_t k[8])
{
	uint64_t t[8];
	GOST_UNROLL_ROUNDS
	for (int r = 0; r < 12; r++) {
		gost_lps(tb, s, t);
		GOST_UNROLL
		for (int i = 0; i < 8; i++) s[i] = k[i] ^ c[r * 8 + i];
		gost_lps(tb, s, k);
		GOST_UNROLL
		for (int i = 0; i < 8; i++) s[i] = t[i] ^ k[i];
	}
}

/* compression g_N(h, m) with K = LPS(N ^ h); n7 = word 7 of N (the other words of N are 0) */
template <class TB>
GD void gost_g(const TB &tb, const uint64_t *c, uint64_t h[8], const uint64_t m[8], uint64_t n7)
{
	uint64_t k[8], s[8];
	h[7] ^= n7;
	gost_lps(tb, h, k);
	h[7] ^= n7;
	GOST_UNROLL
	for (int i = 0; i < 8; i++) { s[i] = m[i] ^ k[i]; h[i] ^= m[i]; }
	gost_e_rounds(tb, c, s, k);
	GOST_UNROLL
	for (int i = 0; i < 8; i++) h[i] ^= s[i];
}

/* same with a message that is zero except word 7 (N blocks and the empty padding block) */
template <class TB>
GD void gost_g_w7(const TB &tb, const uint64_t *c, uint64_t h[8], uint64_t m7, uint64_t n7)
{
	uint64_t k[8], s[8];
	h[7] ^= n7;
	gost_lps(tb, h, k);
	h[7] ^= n7;
	GOST_UNROLL
	for (int i = 0; i < 8; i++) s[i] = k[i];
	s[7] ^= m7;
	h[7] ^= m7;
	gost_e_rounds(tb, c, s, k);
	GOST_UNROLL
	for (int i = 0; i < 8; i++) h[i] ^= s[i];
}

/* word 0 of the compression g_0(h, m) (N = 0): the last round computes only that word */
template <class TB>
GD uint64_t gost_g_w0(const TB &tb, const uint64_t *c, const uint64_t h[8], const uint64_t m[8])
{
	uint64_t k[8], s[8], t[8];
	gost_lps(tb, h, k);
	const uint64_t hm0 = h[0] ^ m[0];
	GOST_UNROLL
	for (int i = 0; i < 8; i++) s[i] = m[i] ^ k[i];
	GOST_UNROLL_ROUNDS
	for (int r = 0; r < 11; r++) {
		gost_lps(tb, s, t);
		GOST_UNROLL
		for (int i = 0; i < 8; i++) s[i] = k[i] ^ c[r * 8 + i];
		gost_lps(tb, s, k);
		GOST_UNROLL
		for (int i = 0; i < 8; i++) s[i] = t[i] ^ k[i];
	}
	/* round 12, word 0 only */
	const uint64_t s0 = gost_lps_w0(tb, s);
	GOST_UNROLL
	for (int i = 0; i < 8; i++) t[i] = k[i] ^ c[11 * 8 + i];
	const uint64_t k0 = gost_lps_w0(tb, t);
	return hm0 ^ s0 ^ k0;
}

/* first-block compression with precomputed keys rk; h = h0 ^ E(m) ^ m with h0 word-wise constant;
 * s holds LPS(m ^ rk[0]) on entry, h holds m on entry */
template <class TB>
GD void gost_g_first(const TB &tb, const uint64_t rk[13][8], uint64_t h0, uint64_t h[8], uint64_t s[8])
{
	uint64_t t[8];
	GOST_UNROLL
	for (int i = 0; i < 8; i++) { s[i] ^= rk[1][i]; h[i] ^= h0; }
	GOST_UNROLL_ROUNDS
	for (int r = 1; r < 12; r++) {
		gost_lps(tb, s, t);
		GOST_UNROLL
		for (int i = 0; i < 8; i++) s[i] = t[i] ^ rk[r + 1][i];
	}
	GOST_UNROLL
	for (int i = 0; i < 8; i++) h[i] ^= s[i];
}

/* a += b, 512-bit big-endian numbers in the byte-array convention (byte 63 least significant) */
GD void gost_add512(uint64_t a[8], const uint64_t b[8])
{
	uint64_t carry = 0;
	GOST_UNROLL
	for (int w = 7; w >= 0; w--) {
		const uint64_t x = gost_bswap64(a[w]), y = gost_bswap64(b[w]);
		const uint64_t s1 = x + y;
		const uint64_t c1 = s1 < x;
		const uint64_t s2 = s1 + carry;
		const uint64_t c2 = s2 < s1;
		a[w] = gost_bswap64(s2);
		carry = c1 | c2;
	}
}

/* a += 1 (byte 63) */
GD void gost_inc512(uint64_t a[8])
{
	uint64_t carry = 1;
	GOST_UNROLL
	for (int w = 7; w >= 0; w--) {
		const uint64_t x = gost_bswap64(a[w]) + carry;
		carry = (carry && x == 0);
		a[w] = gost_bswap64(x);
	}
}

/*
 * gostd of one nonce. FULL = true writes the 32-byte digest (words 0..3) into out,
 * FULL = false returns only word 0 (digest bytes 0..7, little-endian load) - the one checked against the target.
 */
template <class TB, bool FULL>
GD uint64_t gostd_nonce(const TB &tb, const gostd_job_t &J, uint32_t nonce, uint64_t *out,
                        uint64_t *stash, int stride)
{
	uint64_t h[8], s[8];

	/* hash-512, block 1 (nonce in the high half of word 7): s = LPS(m1 ^ rka[0]) from the job constants */
	{
		const uint64_t x7 = (J.m1[7] | ((uint64_t)nonce << 32)) ^ J.rka[0][7];
		GOST_UNROLL
		for (int j = 0; j < 4; j++) s[j] = J.q[j];
		GOST_UNROLL
		for (int j = 4; j < 8; j++) s[j] = J.q[j] ^ tb.t(0, j, gost_byte(x7, j));
		GOST_UNROLL
		for (int i = 0; i < 8; i++) h[i] = J.m1[i];
		h[7] |= (uint64_t)nonce << 32;
	}
	gost_g_first(tb, J.rka, 0, h, s);

	/* block 2 (N = 512), N = 640, Sigma = m1 + m2 (rebuilt from the nonce) */
	gost_g(tb, &J.c[0][0], h, J.m2, GOST_N512);
	gost_g_w7(tb, &J.c[0][0], h, GOST_N640, 0);
	{
		uint64_t sig[8];
		GOST_UNROLL
		for (int i = 0; i < 8; i++) sig[i] = J.m1[i];
		sig[7] |= (uint64_t)nonce << 32;
		gost_add512(sig, J.m2);
		gost_g(tb, &J.c[0][0], h, sig, 0);
	}

	/* hash-256 of the 64-byte digest h: block 1 with precomputed keys */
	/* park the hash-512 digest: it is the Sigma of hash-256 (+1) at the end */
	GOST_UNROLL
	for (int i = 0; i < 8; i++) stash[i * stride] = h[i];
	{
		uint64_t t[8];
		GOST_UNROLL
		for (int i = 0; i < 8; i++) t[i] = h[i] ^ J.rkb[0][i];
		gost_lps(tb, t, s);
	}
	gost_g_first(tb, J.rkb, GOST_IV1, h, s);   /* h becomes the hash-256 chaining value */
	gost_g_w7(tb, &J.c[0][0], h, GOST_PAD7, GOST_N512);
	gost_g_w7(tb, &J.c[0][0], h, GOST_N512, 0);
	/* Sigma = hash-512 digest + 1 */
	uint64_t sig[8];
	GOST_UNROLL
	for (int i = 0; i < 8; i++) sig[i] = stash[i * stride];
	gost_inc512(sig);
	if (FULL) {
		gost_g(tb, &J.c[0][0], h, sig, 0);
		if (out) { out[0] = h[0]; out[1] = h[1]; out[2] = h[2]; out[3] = h[3]; }
		return h[0];
	}
	return gost_g_w0(tb, &J.c[0][0], h, sig);
}

/* host-side table bank: plain tables */
struct gost_host_tb {
	const unsigned long long (*T)[256];
	GH uint64_t t(int i, int j, uint32_t idx) const { (void)j; return T[i][idx]; }
};

/*
 * gostd_prepare_job - job constants from the 80-byte header (nonce bytes ignored) and the 64-bit target.
 * T and C are the Streebog tables (gost_ref_tables() / gost_ref_constants()).
 */
static inline void gostd_prepare_job(gostd_job_t *J, const uint8_t header[80], uint64_t target64,
                                     const unsigned long long (*T)[256], const unsigned char (*C)[64])
{
	gost_host_tb tb;
	tb.T = T;
	uint8_t b[64];
	for (int r = 0; r < 12; r++)
		for (int w = 0; w < 8; w++) {
			uint64_t v = 0;
			for (int k = 7; k >= 0; k--) v = (v << 8) | C[r][8 * w + k];
			J->c[r][w] = v;
		}
	/* m1 = header bytes 16..79, nonce bytes 76..79 cleared */
	for (int i = 0; i < 64; i++) b[i] = header[16 + i];
	b[60] = b[61] = b[62] = b[63] = 0;
	for (int w = 0; w < 8; w++) {
		uint64_t v = 0;
		for (int k = 7; k >= 0; k--) v = (v << 8) | b[8 * w + k];
		J->m1[w] = v;
	}
	/* m2 = 47 zero bytes, 0x01, header bytes 0..15 */
	for (int i = 0; i < 64; i++) b[i] = 0;
	b[47] = 0x01;
	for (int i = 0; i < 16; i++) b[48 + i] = header[i];
	for (int w = 0; w < 8; w++) {
		uint64_t v = 0;
		for (int k = 7; k >= 0; k--) v = (v << 8) | b[8 * w + k];
		J->m2[w] = v;
	}
	/* key schedules */
	uint64_t k[8], t[8];
	for (int pass = 0; pass < 2; pass++) {
		uint64_t (*rk)[8] = pass ? J->rkb : J->rka;
		for (int i = 0; i < 8; i++) t[i] = pass ? GOST_IV1 : 0;
		gost_lps(tb, t, k);
		for (int i = 0; i < 8; i++) rk[0][i] = k[i];
		for (int r = 0; r < 12; r++) {
			for (int i = 0; i < 8; i++) t[i] = k[i] ^ J->c[r][i];
			gost_lps(tb, t, k);
			for (int i = 0; i < 8; i++) rk[r + 1][i] = k[i];
		}
	}
	/* q = LPS(m1 ^ rka[0]) with the T0 lookups of the nonce bytes (word 7, bytes 4..7) left out */
	for (int i = 0; i < 8; i++) t[i] = J->m1[i] ^ J->rka[0][i];
	for (int j = 0; j < 8; j++) {
		uint64_t v = 0;
		for (int i = (j < 4 ? 0 : 1); i < 8; i++) v ^= T[i][gost_byte(t[7 - i], j)];
		J->q[j] = v;
	}
	J->target = target64;
}

#endif
