/* chc_cpu.c - Crypto Connection Miner: Chipcoin (CHC) proof of work on the CPU (since 0.10.1).
 * See chc_cpu.h. Each nonce costs two SHA-256 compressions: the second header block (merkle tail, time, bits, nonce
 * and padding) from the midstate, then the 32-byte digest from the initial state. Code paths:
 *   SHA-NI : the SHA-256 instructions of x86 (sha256rnds2 / sha256msg1 / sha256msg2), one nonce at a time;
 *   AVX2   : eight nonces at a time in 256-bit registers;
 *   scalar : portable C.
 * The paths are chosen at run time (cpuid), so one binary runs on every x86-64 CPU. The miner checks every path
 * against gm_sha256d and a real Chipcoin block before mining (cpu_reference / CPU self test). */
#include <string.h>
#include "chc_cpu.h"

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#define CHC_X86 1
#include <immintrin.h>
#if defined(_MSC_VER)
#include <intrin.h>
#define CHC_TGT_SHA
#define CHC_TGT_AVX2
#else
#include <cpuid.h>
#define CHC_TGT_SHA __attribute__((target("sha,sse4.1,ssse3")))
#define CHC_TGT_AVX2 __attribute__((target("avx2")))
#endif
#endif

static const uint32_t K256[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};
static const uint32_t IV256[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };

static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static uint32_t bswap32(uint32_t x) { return (x >> 24) | ((x >> 8) & 0xFF00u) | ((x << 8) & 0xFF0000u) | (x << 24); }

/* ------------------------------------------------------------------------------------------------ scalar */
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void compress_words(uint32_t h[8], const uint32_t in[16])
{
	uint32_t w[64], a, b, c, d, e, f, g, hh;
	int i;
	for (i = 0; i < 16; i++) w[i] = in[i];
	for (i = 16; i < 64; i++) {
		const uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
		const uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}
	a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4]; f = h[5]; g = h[6]; hh = h[7];
	for (i = 0; i < 64; i++) {
		const uint32_t t1 = hh + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
		const uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

void chc_cpu_prepare(const uint8_t header[80], chc_cpu_job *job)
{
	uint32_t w[16];
	int i;
	for (i = 0; i < 8; i++) job->mid[i] = IV256[i];
	for (i = 0; i < 16; i++) w[i] = be32(header + 4 * i);
	compress_words(job->mid, w);
	for (i = 0; i < 3; i++) job->tail[i] = be32(header + 64 + 4 * i);
}

static uint32_t scan_scalar(const chc_cpu_job *job, uint32_t first, uint32_t count, uint64_t target64, uint32_t *out,
                            uint32_t max_out)
{
	uint32_t found = 0, k;
	uint32_t b2[16] = { 0 }, b3[16] = { 0 };
	b2[0] = job->tail[0]; b2[1] = job->tail[1]; b2[2] = job->tail[2];
	b2[4] = 0x80000000u; b2[15] = 640;
	b3[8] = 0x80000000u; b3[15] = 256;
	for (k = 0; k < count; k++) {
		const uint32_t nonce = first + k;
		uint32_t h1[8], h2[8];
		int i;
		b2[3] = bswap32(nonce);
		memcpy(h1, job->mid, 32);
		compress_words(h1, b2);
		for (i = 0; i < 8; i++) { b3[i] = h1[i]; h2[i] = IV256[i]; }
		compress_words(h2, b3);
		if ((((uint64_t)h2[0] << 32) | h2[1]) <= target64 && found < max_out) out[found++] = nonce;
	}
	return found;
}

#ifdef CHC_X86
/* ------------------------------------------------------------------------------------------------ SHA-NI */
/* state as two vectors in the order of the SHA instructions: s0 = (F, E, B, A), s1 = (H, G, D, C) (lane 0 first);
 * m0..m3 = message words W0..W15, lane 0 = lowest word */
CHC_TGT_SHA static void shani_rounds(__m128i *s0, __m128i *s1, __m128i m0, __m128i m1, __m128i m2, __m128i m3)
{
	__m128i M[4];
	__m128i st0 = *s0, st1 = *s1;
	const __m128i save0 = st0, save1 = st1;
	int g;
	M[0] = m0; M[1] = m1; M[2] = m2; M[3] = m3;
	for (g = 0; g < 16; g++) {
		__m128i msg = _mm_add_epi32(M[g & 3], _mm_loadu_si128((const __m128i *)&K256[4 * g]));
		st1 = _mm_sha256rnds2_epu32(st1, st0, msg);
		if (g >= 3 && g < 15) {
			const __m128i tmp = _mm_alignr_epi8(M[g & 3], M[(g - 1) & 3], 4);
			M[(g + 1) & 3] = _mm_add_epi32(M[(g + 1) & 3], tmp);
			M[(g + 1) & 3] = _mm_sha256msg2_epu32(M[(g + 1) & 3], M[g & 3]);
		}
		msg = _mm_shuffle_epi32(msg, 0x0E);
		st0 = _mm_sha256rnds2_epu32(st0, st1, msg);
		if (g >= 1 && g < 13) M[(g - 1) & 3] = _mm_sha256msg1_epu32(M[(g - 1) & 3], M[g & 3]);
	}
	*s0 = _mm_add_epi32(st0, save0);
	*s1 = _mm_add_epi32(st1, save1);
}

/* (A..D) (E..H) -> SHA-NI order */
CHC_TGT_SHA static void shani_from_words(const uint32_t h[8], __m128i *s0, __m128i *s1)
{
	__m128i tmp = _mm_loadu_si128((const __m128i *)&h[0]);
	__m128i t1 = _mm_loadu_si128((const __m128i *)&h[4]);
	tmp = _mm_shuffle_epi32(tmp, 0xB1);          /* CDAB */
	t1 = _mm_shuffle_epi32(t1, 0x1B);            /* EFGH */
	*s0 = _mm_alignr_epi8(tmp, t1, 8);           /* ABEF */
	*s1 = _mm_blend_epi16(t1, tmp, 0xF0);        /* CDGH */
}

/* SHA-NI order -> words A..D in lo, E..H in hi */
CHC_TGT_SHA static void shani_to_words(__m128i s0, __m128i s1, __m128i *lo, __m128i *hi)
{
	const __m128i tmp = _mm_shuffle_epi32(s0, 0x1B);   /* FEBA */
	s1 = _mm_shuffle_epi32(s1, 0xB1);                   /* DCHG */
	*lo = _mm_blend_epi16(tmp, s1, 0xF0);               /* DCBA */
	*hi = _mm_alignr_epi8(s1, tmp, 8);                  /* HGFE */
}

CHC_TGT_SHA static uint32_t scan_shani(const chc_cpu_job *job, uint32_t first, uint32_t count, uint64_t target64,
                                       uint32_t *out, uint32_t max_out)
{
	__m128i mid0, mid1, iv0, iv1;
	uint32_t found = 0, k;
	const __m128i pad2 = _mm_setr_epi32((int)0x80000000u, 0, 0, 0);
	const __m128i len2 = _mm_setr_epi32(0, 0, 0, 640);
	const __m128i pad3 = _mm_setr_epi32((int)0x80000000u, 0, 0, 0);
	const __m128i len3 = _mm_setr_epi32(0, 0, 0, 256);
	const __m128i zero = _mm_setzero_si128();
	shani_from_words(job->mid, &mid0, &mid1);
	shani_from_words(IV256, &iv0, &iv1);
	for (k = 0; k < count; k++) {
		const uint32_t nonce = first + k;
		__m128i a0 = mid0, a1 = mid1, lo, hi, b0 = iv0, b1 = iv1;
		const __m128i m0 = _mm_setr_epi32((int)job->tail[0], (int)job->tail[1], (int)job->tail[2], (int)bswap32(nonce));
		uint32_t hA, hB;
		shani_rounds(&a0, &a1, m0, pad2, zero, len2);
		shani_to_words(a0, a1, &lo, &hi);
		shani_rounds(&b0, &b1, lo, hi, pad3, len3);
		/* b0 = (F, E, B, A) */
		hA = (uint32_t)_mm_extract_epi32(b0, 3);
		hB = (uint32_t)_mm_extract_epi32(b0, 2);
		if ((((uint64_t)hA << 32) | hB) <= target64 && found < max_out) out[found++] = nonce;
	}
	return found;
}

/* ------------------------------------------------------------------------------------------------ AVX2 x8 */
#define V8ROR(x, n) _mm256_or_si256(_mm256_srli_epi32((x), (n)), _mm256_slli_epi32((x), 32 - (n)))

CHC_TGT_AVX2 static void avx2_compress(__m256i h[8], __m256i w[16])
{
	__m256i a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
	int i;
	for (i = 0; i < 64; i++) {
		__m256i wi;
		if (i < 16) wi = w[i];
		else {
			const __m256i w15 = w[(i - 15) & 15], w2 = w[(i - 2) & 15];
			const __m256i s0 = _mm256_xor_si256(_mm256_xor_si256(V8ROR(w15, 7), V8ROR(w15, 18)), _mm256_srli_epi32(w15, 3));
			const __m256i s1 = _mm256_xor_si256(_mm256_xor_si256(V8ROR(w2, 17), V8ROR(w2, 19)), _mm256_srli_epi32(w2, 10));
			wi = _mm256_add_epi32(_mm256_add_epi32(w[i & 15], s0), _mm256_add_epi32(w[(i - 7) & 15], s1));
			w[i & 15] = wi;
		}
		{
			const __m256i S1 = _mm256_xor_si256(_mm256_xor_si256(V8ROR(e, 6), V8ROR(e, 11)), V8ROR(e, 25));
			const __m256i ch = _mm256_xor_si256(_mm256_and_si256(e, f), _mm256_andnot_si256(e, g));
			const __m256i t1 = _mm256_add_epi32(_mm256_add_epi32(_mm256_add_epi32(hh, S1), _mm256_add_epi32(ch, wi)),
			                                    _mm256_set1_epi32((int)K256[i]));
			const __m256i S0 = _mm256_xor_si256(_mm256_xor_si256(V8ROR(a, 2), V8ROR(a, 13)), V8ROR(a, 22));
			const __m256i mj = _mm256_xor_si256(_mm256_and_si256(a, b), _mm256_and_si256(c, _mm256_xor_si256(a, b)));
			const __m256i t2 = _mm256_add_epi32(S0, mj);
			hh = g; g = f; f = e; e = _mm256_add_epi32(d, t1); d = c; c = b; b = a; a = _mm256_add_epi32(t1, t2);
		}
	}
	h[0] = _mm256_add_epi32(h[0], a); h[1] = _mm256_add_epi32(h[1], b); h[2] = _mm256_add_epi32(h[2], c);
	h[3] = _mm256_add_epi32(h[3], d); h[4] = _mm256_add_epi32(h[4], e); h[5] = _mm256_add_epi32(h[5], f);
	h[6] = _mm256_add_epi32(h[6], g); h[7] = _mm256_add_epi32(h[7], hh);
}

CHC_TGT_AVX2 static uint32_t scan_avx2(const chc_cpu_job *job, uint32_t first, uint32_t count, uint64_t target64,
                                       uint32_t *out, uint32_t max_out)
{
	uint32_t found = 0, k;
	const uint32_t full = count & ~7u;
	for (k = 0; k < full; k += 8) {
		__m256i h1[8], h2[8], w[16];
		uint32_t A[8], B[8], n[8];
		int i;
		for (i = 0; i < 8; i++) { n[i] = first + k + (uint32_t)i; A[i] = bswap32(n[i]); }
		for (i = 0; i < 8; i++) h1[i] = _mm256_set1_epi32((int)job->mid[i]);
		w[0] = _mm256_set1_epi32((int)job->tail[0]);
		w[1] = _mm256_set1_epi32((int)job->tail[1]);
		w[2] = _mm256_set1_epi32((int)job->tail[2]);
		w[3] = _mm256_loadu_si256((const __m256i *)A);
		w[4] = _mm256_set1_epi32((int)0x80000000u);
		for (i = 5; i < 15; i++) w[i] = _mm256_setzero_si256();
		w[15] = _mm256_set1_epi32(640);
		avx2_compress(h1, w);
		for (i = 0; i < 8; i++) { w[i] = h1[i]; h2[i] = _mm256_set1_epi32((int)IV256[i]); }
		w[8] = _mm256_set1_epi32((int)0x80000000u);
		for (i = 9; i < 15; i++) w[i] = _mm256_setzero_si256();
		w[15] = _mm256_set1_epi32(256);
		avx2_compress(h2, w);
		_mm256_storeu_si256((__m256i *)A, h2[0]);
		_mm256_storeu_si256((__m256i *)B, h2[1]);
		for (i = 0; i < 8; i++)
			if ((((uint64_t)A[i] << 32) | B[i]) <= target64 && found < max_out) out[found++] = n[i];
	}
	if (full < count) found += scan_scalar(job, first + full, count - full, target64, out + found, max_out - found);
	return found;
}

/* ------------------------------------------------------------------------------------------------ cpuid */
static void cpuidex(uint32_t leaf, uint32_t sub, uint32_t r[4])
{
#if defined(_MSC_VER)
	int x[4];
	__cpuidex(x, (int)leaf, (int)sub);
	r[0] = (uint32_t)x[0]; r[1] = (uint32_t)x[1]; r[2] = (uint32_t)x[2]; r[3] = (uint32_t)x[3];
#else
	unsigned a = 0, b = 0, c = 0, d = 0;
	if (!__get_cpuid_count(leaf, sub, &a, &b, &c, &d)) a = b = c = d = 0;
	r[0] = a; r[1] = b; r[2] = c; r[3] = d;
#endif
}

static uint64_t xcr0(void)
{
#if defined(_MSC_VER)
	return (uint64_t)_xgetbv(0);
#else
	uint32_t lo, hi;
	__asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
	return ((uint64_t)hi << 32) | lo;
#endif
}
#endif /* CHC_X86 */

int chc_cpu_supported(int path)
{
	if (path == CHC_CPU_SCALAR) return 1;
#ifdef CHC_X86
	{
		uint32_t r0[4], r1[4], r7[4];
		cpuidex(0, 0, r0);
		if (r0[0] < 7) return 0;
		cpuidex(1, 0, r1);
		cpuidex(7, 0, r7);
		{
			const int ssse3 = (r1[2] >> 9) & 1, sse41 = (r1[2] >> 19) & 1, osxsave = (r1[2] >> 27) & 1, avx = (r1[2] >> 28) & 1;
			const int sha = (r7[1] >> 29) & 1, avx2 = (r7[1] >> 5) & 1;
			if (path == CHC_CPU_SHANI) return sha && ssse3 && sse41;
			if (path == CHC_CPU_AVX2) return avx2 && avx && osxsave && (xcr0() & 6) == 6;
		}
	}
#endif
	return 0;
}

int chc_cpu_best_path(void)
{
	if (chc_cpu_supported(CHC_CPU_SHANI)) return CHC_CPU_SHANI;
	if (chc_cpu_supported(CHC_CPU_AVX2)) return CHC_CPU_AVX2;
	return CHC_CPU_SCALAR;
}

const char *chc_cpu_path_name(int path)
{
	return path == CHC_CPU_SHANI ? "SHA-NI" : path == CHC_CPU_AVX2 ? "AVX2 x8" : "portable C";
}

uint32_t chc_cpu_scan(int path, const chc_cpu_job *job, uint32_t first, uint32_t count, uint64_t target64,
                      uint32_t *out, uint32_t max_out)
{
#ifdef CHC_X86
	if (path == CHC_CPU_SHANI) return scan_shani(job, first, count, target64, out, max_out);
	if (path == CHC_CPU_AVX2) return scan_avx2(job, first, count, target64, out, max_out);
#endif
	return scan_scalar(job, first, count, target64, out, max_out);
}
