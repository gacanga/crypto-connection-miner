/* ting_gpu.cu - Crypto Connection Miner: Ting proof of work (Daler, DLR) on NVIDIA GPUs, see ting_gpu.h.
 * Written for Crypto Connection Miner 0.7.0 (09/11/2026), GPL-3 like the rest of the miner. */
#include "ting_gpu.h"
#include <string.h>

#define TING_TPB 256
#define TING_MAX_DEV 16

/* ------------------------------------------------------------------------------------------------
 * SHA-256 compression, shared by the host (midstate, references) and the device
 * ---------------------------------------------------------------------------------------------- */
#define ROTR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define S0(x) (ROTR32(x, 2) ^ ROTR32(x, 13) ^ ROTR32(x, 22))
#define S1(x) (ROTR32(x, 6) ^ ROTR32(x, 11) ^ ROTR32(x, 25))
#define s0(x) (ROTR32(x, 7) ^ ROTR32(x, 18) ^ ((x) >> 3))
#define s1(x) (ROTR32(x, 17) ^ ROTR32(x, 19) ^ ((x) >> 10))
#define CH(x, y, z) ((z) ^ ((x) & ((y) ^ (z))))
#define MAJ(x, y, z) (((x) & (y)) | ((z) & ((x) | (y))))

static const uint32_t h_K[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

__constant__ uint32_t d_K[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

static const uint32_t h_IV[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

/* host: full compression of one 64-byte block into state */
static void h_compress(uint32_t st[8], const uint8_t blk[64])
{
	uint32_t W[64];
	for (int i = 0; i < 16; i++) W[i] = be32(blk + 4 * i);
	for (int i = 16; i < 64; i++) W[i] = s1(W[i - 2]) + W[i - 7] + s0(W[i - 15]) + W[i - 16];
	uint32_t a = st[0], b = st[1], c = st[2], d = st[3], e = st[4], f = st[5], g = st[6], h = st[7];
	for (int i = 0; i < 64; i++) {
		const uint32_t t1 = h + S1(e) + CH(e, f, g) + h_K[i] + W[i];
		const uint32_t t2 = S0(a) + MAJ(a, b, c);
		h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	st[0] += a; st[1] += b; st[2] += c; st[3] += d; st[4] += e; st[5] += f; st[6] += g; st[7] += h;
}

/* "Ting/" || u16le(5) || "block" */
static const uint8_t TAG[12] = {'T', 'i', 'n', 'g', '/', 5, 0, 'b', 'l', 'o', 'c', 'k'};

void ting_message(const uint8_t prefix[TING_NONCE_OFFSET], const uint8_t nonce[16], uint8_t msg[12 + TING_HEADER_SIZE])
{
	memcpy(msg, TAG, 12);
	memcpy(msg + 12, prefix, TING_NONCE_OFFSET);
	memcpy(msg + 12 + TING_NONCE_OFFSET, nonce, 16);
}

/* the 5 padded blocks of the 306-byte message */
static void padded(const uint8_t msg[306], uint8_t out[320])
{
	memset(out, 0, 320);
	memcpy(out, msg, 306);
	out[306] = 0x80;
	const uint64_t bits = 306ull * 8;
	for (int i = 0; i < 8; i++) out[319 - i] = (uint8_t)(bits >> (8 * i));
}

void ting_block_id(const uint8_t prefix[TING_NONCE_OFFSET], const uint8_t nonce[16], uint8_t id[32])
{
	uint8_t msg[306], blk[320];
	ting_message(prefix, nonce, msg);
	padded(msg, blk);
	uint32_t st[8];
	memcpy(st, h_IV, sizeof(st));
	for (int b = 0; b < 5; b++) h_compress(st, blk + 64 * b);
	for (int i = 0; i < 8; i++) {
		id[4 * i] = (uint8_t)(st[i] >> 24); id[4 * i + 1] = (uint8_t)(st[i] >> 16);
		id[4 * i + 2] = (uint8_t)(st[i] >> 8); id[4 * i + 3] = (uint8_t)st[i];
	}
}

/* ------------------------------------------------------------------------------------------------
 * device
 * ---------------------------------------------------------------------------------------------- */
struct ting_job_t {
	uint32_t mid[8];      /* state after the first 4 blocks */
	uint32_t st[8];       /* a..h after rounds 0..7 of the 5th block */
	uint32_t w[16];       /* words of the 5th block, counter bytes zeroed (W8 bits 0..15, W9 bits 16..31) */
	/* parts of the work that do not depend on the counter (W8 and W9 do), computed once per job:
	 * round 8: t1 = r8 + W8, t2 = t2_8; schedule: W16 = p16 + W9, W17 = p17, W18 = s1(W16) + p18, W19 = p19,
	 * W20 = s1(W18) + p20, W21 = p21, W22 = s1(W20) + p22, W23 = W16 + s0(W8) + p23 */
	uint32_t r8, t2_8;
	uint32_t p16, p17, p18, p19, p20, p21, p22, p23;
	uint64_t target64;    /* (H0 << 32 | H1) must be <= this */
};

__constant__ ting_job_t c_tj;

/* nonce byte k sits at offset 34 + k of the 5th block: counter byte 0 -> W8 bits 8..15, byte 1 -> W8 bits 0..7,
 * byte 2 -> W9 bits 24..31, byte 3 -> W9 bits 16..23 */
#define RND(a, b, c, d, e, f, g, h, k, w) do { \
	const uint32_t t1_ = (h) + S1(e) + CH(e, f, g) + (k) + (w); \
	const uint32_t t2_ = S0(a) + MAJ(a, b, c); \
	(d) += t1_; (h) = t1_ + t2_; } while (0)

__global__ void __launch_bounds__(TING_TPB) k_ting(uint32_t start, uint32_t npt, uint32_t *res)
{
	const uint32_t stride = gridDim.x * TING_TPB;
	uint32_t n = start + blockIdx.x * TING_TPB + threadIdx.x;
	for (uint32_t it = 0; it < npt; it++, n += stride) {
		/* W[i & 15] ring of the message schedule; slots 10..15 never depend on the counter */
		uint32_t W[16];
#pragma unroll
		for (int i = 10; i < 16; i++) W[i] = c_tj.w[i];
		W[8] = c_tj.w[8] | ((n & 0xFFu) << 8) | ((n >> 8) & 0xFFu);
		W[9] = c_tj.w[9] | (((n >> 16) & 0xFFu) << 24) | (((n >> 24) & 0xFFu) << 16);
		uint32_t a = c_tj.st[0], b = c_tj.st[1], c = c_tj.st[2], d = c_tj.st[3];
		uint32_t e = c_tj.st[4], f = c_tj.st[5], g = c_tj.st[6], h = c_tj.st[7];
		/* round 8: everything but W8 was computed on the host */
		{
			const uint32_t t1 = c_tj.r8 + W[8];
			d += t1;
			h = t1 + c_tj.t2_8;
		}
		/* rounds 9..15 */
		RND(h, a, b, c, d, e, f, g, d_K[9], W[9]);
		RND(g, h, a, b, c, d, e, f, d_K[10], W[10]);
		RND(f, g, h, a, b, c, d, e, d_K[11], W[11]);
		RND(e, f, g, h, a, b, c, d, d_K[12], W[12]);
		RND(d, e, f, g, h, a, b, c, d_K[13], W[13]);
		RND(c, d, e, f, g, h, a, b, d_K[14], W[14]);
		RND(b, c, d, e, f, g, h, a, d_K[15], W[15]);
		/* schedule words 16..23 from the precomputed parts (slots 0..7 of the ring) */
		W[0] = c_tj.p16 + W[9];
		W[1] = c_tj.p17;
		W[2] = s1(W[0]) + c_tj.p18;
		W[3] = c_tj.p19;
		W[4] = s1(W[2]) + c_tj.p20;
		W[5] = c_tj.p21;
		W[6] = s1(W[4]) + c_tj.p22;
		W[7] = W[0] + s0(W[8]) + c_tj.p23;
		RND(a, b, c, d, e, f, g, h, d_K[16], W[0]);
		RND(h, a, b, c, d, e, f, g, d_K[17], W[1]);
		RND(g, h, a, b, c, d, e, f, d_K[18], W[2]);
		RND(f, g, h, a, b, c, d, e, d_K[19], W[3]);
		RND(e, f, g, h, a, b, c, d, d_K[20], W[4]);
		RND(d, e, f, g, h, a, b, c, d_K[21], W[5]);
		RND(c, d, e, f, g, h, a, b, d_K[22], W[6]);
		RND(b, c, d, e, f, g, h, a, d_K[23], W[7]);
		/* rounds 24..63: W[t] = s1(W[t-2]) + W[t-7] + s0(W[t-15]) + W[t-16], slot t & 15 holds W[t-16] before */
#pragma unroll
		for (int r = 24; r < 64; r += 8) {
#pragma unroll
			for (int j = 0; j < 8; j++) {
				const int t = r + j;
				W[t & 15] += s1(W[(t - 2) & 15]) + W[(t - 7) & 15] + s0(W[(t - 15) & 15]);
			}
			RND(a, b, c, d, e, f, g, h, d_K[r + 0], W[(r + 0) & 15]);
			RND(h, a, b, c, d, e, f, g, d_K[r + 1], W[(r + 1) & 15]);
			RND(g, h, a, b, c, d, e, f, d_K[r + 2], W[(r + 2) & 15]);
			RND(f, g, h, a, b, c, d, e, d_K[r + 3], W[(r + 3) & 15]);
			RND(e, f, g, h, a, b, c, d, d_K[r + 4], W[(r + 4) & 15]);
			RND(d, e, f, g, h, a, b, c, d_K[r + 5], W[(r + 5) & 15]);
			RND(c, d, e, f, g, h, a, b, d_K[r + 6], W[(r + 6) & 15]);
			RND(b, c, d, e, f, g, h, a, d_K[r + 7], W[(r + 7) & 15]);
		}
		const uint32_t H0 = a + c_tj.mid[0], H1 = b + c_tj.mid[1];
		const uint64_t top = ((uint64_t)H0 << 32) | H1;
		if (top <= c_tj.target64) {
			const uint32_t slot = atomicAdd(&res[0], 1u);
			if (slot < TING_MAX_RES) res[1 + slot] = n;
		}
	}
}

static uint32_t *g_res[TING_MAX_DEV];
static int g_grid[TING_MAX_DEV];

cudaError_t ting_init(int dev, int *grid)
{
	if (dev < 0 || dev >= TING_MAX_DEV) return cudaErrorInvalidDevice;
	cudaDeviceProp prop;
	cudaError_t e = cudaGetDeviceProperties(&prop, dev);
	if (e != cudaSuccess) return e;
	int bps = 0;
	e = cudaOccupancyMaxActiveBlocksPerMultiprocessor(&bps, (const void *)k_ting, TING_TPB, 0);
	if (e != cudaSuccess) return e;
	if (bps <= 0) bps = 1;
	g_grid[dev] = prop.multiProcessorCount * bps * 4;
	if (!g_res[dev]) {
		e = cudaMalloc(&g_res[dev], sizeof(uint32_t) * (1 + TING_MAX_RES));
		if (e != cudaSuccess) return e;
	}
	*grid = g_grid[dev];
	return cudaSuccess;
}

void ting_free(int dev)
{
	if (dev < 0 || dev >= TING_MAX_DEV) return;
	if (g_res[dev]) cudaFree(g_res[dev]);
	g_res[dev] = NULL;
}

cudaError_t ting_set_job(int dev, const uint8_t prefix[TING_NONCE_OFFSET], const uint8_t nonce_hi[12], uint64_t target64)
{
	(void)dev;
	uint8_t nonce[16] = {0}, msg[306], blk[320];
	memcpy(nonce + 4, nonce_hi, 12);
	ting_message(prefix, nonce, msg);
	padded(msg, blk);
	ting_job_t J;
	memcpy(J.mid, h_IV, sizeof(J.mid));
	for (int b = 0; b < 4; b++) h_compress(J.mid, blk + 64 * b);
	const uint8_t *b4 = blk + 256;
	for (int i = 0; i < 16; i++) J.w[i] = be32(b4 + 4 * i);
	/* counter bytes are 0 in nonce[0..3]: W8 bits 0..15 and W9 bits 16..31 are already zero */
	uint32_t a = J.mid[0], b = J.mid[1], c = J.mid[2], d = J.mid[3], e = J.mid[4], f = J.mid[5], g = J.mid[6], h = J.mid[7];
	for (int i = 0; i < 8; i++) {
		const uint32_t t1 = h + S1(e) + CH(e, f, g) + h_K[i] + J.w[i];
		const uint32_t t2 = S0(a) + MAJ(a, b, c);
		h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	J.st[0] = a; J.st[1] = b; J.st[2] = c; J.st[3] = d; J.st[4] = e; J.st[5] = f; J.st[6] = g; J.st[7] = h;
	/* round 8 without W8 */
	J.r8 = h + S1(e) + CH(e, f, g) + h_K[8];
	J.t2_8 = S0(a) + MAJ(a, b, c);
	/* schedule parts that do not depend on W8 / W9 */
	const uint32_t *w = J.w;
	J.p16 = s1(w[14]) + s0(w[1]) + w[0];
	J.p17 = s1(w[15]) + w[10] + s0(w[2]) + w[1];
	J.p18 = w[11] + s0(w[3]) + w[2];
	J.p19 = s1(J.p17) + w[12] + s0(w[4]) + w[3];
	J.p20 = w[13] + s0(w[5]) + w[4];
	J.p21 = s1(J.p19) + w[14] + s0(w[6]) + w[5];
	J.p22 = w[15] + s0(w[7]) + w[6];
	J.p23 = s1(J.p21) + w[7];
	J.target64 = target64;
	return cudaMemcpyToSymbol(c_tj, &J, sizeof(J));
}

cudaError_t ting_scan(int dev, uint32_t start, uint32_t npt, uint32_t res[1 + TING_MAX_RES])
{
	if (dev < 0 || dev >= TING_MAX_DEV || !g_res[dev]) return cudaErrorInvalidValue;
	cudaError_t e = cudaMemsetAsync(g_res[dev], 0, sizeof(uint32_t));
	if (e != cudaSuccess) return e;
	k_ting<<<g_grid[dev], TING_TPB>>>(start, npt, g_res[dev]);
	e = cudaGetLastError();
	if (e != cudaSuccess) return e;
	return cudaMemcpy(res, g_res[dev], sizeof(uint32_t) * (1 + TING_MAX_RES), cudaMemcpyDeviceToHost);
}
