/* chc_gpu.cu - Crypto Connection Miner: Chipcoin proof of work (CHC) on NVIDIA GPUs, see chc_gpu.h.
 * Written for Crypto Connection Miner 0.10.0 (13/11/2026), GPL-3 like the rest of the miner. */
#include "chc_gpu.h"
#include <string.h>

#define CHC_TPB 256
#define CHC_MAX_DEV 16

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

__constant__ uint32_t c_K[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

#define IV0 0x6a09e667u
#define IV1 0xbb67ae85u
#define IV2 0x3c6ef372u
#define IV3 0xa54ff53au
#define IV4 0x510e527fu
#define IV5 0x9b05688cu
#define IV6 0x1f83d9abu
#define IV7 0x5be0cd19u

static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

struct chc_job_t {
	uint32_t mid[8];      /* SHA-256 state after the first 64 header bytes */
	uint32_t st[8];       /* a..h after rounds 0..2 of the second block */
	uint32_t w0, w1, w2;  /* merkle tail, time, bits (big-endian words of header bytes 64..75) */
	uint64_t target64;    /* (H0 << 32 | H1) of the final digest must be <= this */
};

__constant__ chc_job_t c_job;

#define RND(a, b, c, d, e, f, g, h, k, w) do { \
	const uint32_t t1_ = (h) + S1(e) + CH(e, f, g) + (k) + (w); \
	const uint32_t t2_ = S0(a) + MAJ(a, b, c); \
	(d) += t1_; (h) = t1_ + t2_; } while (0)

/* 64 rounds over the ring W[16] (W[0..15] = message words on entry), 8 rounds per step */
#define ROUNDS64(a, b, c, d, e, f, g, h, W) do { \
	RND(a, b, c, d, e, f, g, h, c_K[0], W[0]);  RND(h, a, b, c, d, e, f, g, c_K[1], W[1]); \
	RND(g, h, a, b, c, d, e, f, c_K[2], W[2]);  RND(f, g, h, a, b, c, d, e, c_K[3], W[3]); \
	RND(e, f, g, h, a, b, c, d, c_K[4], W[4]);  RND(d, e, f, g, h, a, b, c, c_K[5], W[5]); \
	RND(c, d, e, f, g, h, a, b, c_K[6], W[6]);  RND(b, c, d, e, f, g, h, a, c_K[7], W[7]); \
	RND(a, b, c, d, e, f, g, h, c_K[8], W[8]);  RND(h, a, b, c, d, e, f, g, c_K[9], W[9]); \
	RND(g, h, a, b, c, d, e, f, c_K[10], W[10]); RND(f, g, h, a, b, c, d, e, c_K[11], W[11]); \
	RND(e, f, g, h, a, b, c, d, c_K[12], W[12]); RND(d, e, f, g, h, a, b, c, c_K[13], W[13]); \
	RND(c, d, e, f, g, h, a, b, c_K[14], W[14]); RND(b, c, d, e, f, g, h, a, c_K[15], W[15]); \
	_Pragma("unroll") \
	for (int r_ = 16; r_ < 64; r_ += 8) { \
		_Pragma("unroll") \
		for (int j_ = 0; j_ < 8; j_++) { \
			const int t_ = r_ + j_; \
			W[t_ & 15] += s1(W[(t_ - 2) & 15]) + W[(t_ - 7) & 15] + s0(W[(t_ - 15) & 15]); \
		} \
		RND(a, b, c, d, e, f, g, h, c_K[r_ + 0], W[(r_ + 0) & 15]); \
		RND(h, a, b, c, d, e, f, g, c_K[r_ + 1], W[(r_ + 1) & 15]); \
		RND(g, h, a, b, c, d, e, f, c_K[r_ + 2], W[(r_ + 2) & 15]); \
		RND(f, g, h, a, b, c, d, e, c_K[r_ + 3], W[(r_ + 3) & 15]); \
		RND(e, f, g, h, a, b, c, d, c_K[r_ + 4], W[(r_ + 4) & 15]); \
		RND(d, e, f, g, h, a, b, c, c_K[r_ + 5], W[(r_ + 5) & 15]); \
		RND(c, d, e, f, g, h, a, b, c_K[r_ + 6], W[(r_ + 6) & 15]); \
		RND(b, c, d, e, f, g, h, a, c_K[r_ + 7], W[(r_ + 7) & 15]); \
	} } while (0)

__global__ void __launch_bounds__(CHC_TPB) k_chc(uint32_t start, uint32_t npt, uint32_t *res)
{
	const uint32_t stride = gridDim.x * CHC_TPB;
	uint32_t n = start + blockIdx.x * CHC_TPB + threadIdx.x;
	for (uint32_t it = 0; it < npt; it++, n += stride) {
		/* second block of the header: W0..W2 fixed, W3 = counter, then padding (80 bytes = 640 bits) */
		uint32_t W[16];
		W[0] = c_job.w0; W[1] = c_job.w1; W[2] = c_job.w2; W[3] = n;
		W[4] = 0x80000000u;
#pragma unroll
		for (int i = 5; i < 15; i++) W[i] = 0;
		W[15] = 640;
		uint32_t a = c_job.st[0], b = c_job.st[1], c = c_job.st[2], d = c_job.st[3];
		uint32_t e = c_job.st[4], f = c_job.st[5], g = c_job.st[6], h = c_job.st[7];
		/* rounds 3..15 (0..2 done on the host); the register roles after 3 rounds are rotated by 3 */
		RND(f, g, h, a, b, c, d, e, c_K[3], W[3]);
		RND(e, f, g, h, a, b, c, d, c_K[4], W[4]);
		RND(d, e, f, g, h, a, b, c, c_K[5], W[5]);
		RND(c, d, e, f, g, h, a, b, c_K[6], W[6]);
		RND(b, c, d, e, f, g, h, a, c_K[7], W[7]);
		RND(a, b, c, d, e, f, g, h, c_K[8], W[8]);
		RND(h, a, b, c, d, e, f, g, c_K[9], W[9]);
		RND(g, h, a, b, c, d, e, f, c_K[10], W[10]);
		RND(f, g, h, a, b, c, d, e, c_K[11], W[11]);
		RND(e, f, g, h, a, b, c, d, c_K[12], W[12]);
		RND(d, e, f, g, h, a, b, c, c_K[13], W[13]);
		RND(c, d, e, f, g, h, a, b, c_K[14], W[14]);
		RND(b, c, d, e, f, g, h, a, c_K[15], W[15]);
#pragma unroll
		for (int r = 16; r < 64; r += 8) {
#pragma unroll
			for (int j = 0; j < 8; j++) {
				const int t = r + j;
				W[t & 15] += s1(W[(t - 2) & 15]) + W[(t - 7) & 15] + s0(W[(t - 15) & 15]);
			}
			RND(a, b, c, d, e, f, g, h, c_K[r + 0], W[(r + 0) & 15]);
			RND(h, a, b, c, d, e, f, g, c_K[r + 1], W[(r + 1) & 15]);
			RND(g, h, a, b, c, d, e, f, c_K[r + 2], W[(r + 2) & 15]);
			RND(f, g, h, a, b, c, d, e, c_K[r + 3], W[(r + 3) & 15]);
			RND(e, f, g, h, a, b, c, d, c_K[r + 4], W[(r + 4) & 15]);
			RND(d, e, f, g, h, a, b, c, c_K[r + 5], W[(r + 5) & 15]);
			RND(c, d, e, f, g, h, a, b, c_K[r + 6], W[(r + 6) & 15]);
			RND(b, c, d, e, f, g, h, a, c_K[r + 7], W[(r + 7) & 15]);
		}
		/* first digest = second message: H0..H7, padding, length 256 bits */
		uint32_t M[16];
		M[0] = c_job.mid[0] + a; M[1] = c_job.mid[1] + b; M[2] = c_job.mid[2] + c; M[3] = c_job.mid[3] + d;
		M[4] = c_job.mid[4] + e; M[5] = c_job.mid[5] + f; M[6] = c_job.mid[6] + g; M[7] = c_job.mid[7] + h;
		M[8] = 0x80000000u;
#pragma unroll
		for (int i = 9; i < 15; i++) M[i] = 0;
		M[15] = 256;
		a = IV0; b = IV1; c = IV2; d = IV3; e = IV4; f = IV5; g = IV6; h = IV7;
		ROUNDS64(a, b, c, d, e, f, g, h, M);
		/* Chipcoin: the digest's first bytes (H0, H1 big-endian) are the most significant */
		const uint64_t top = ((uint64_t)(a + IV0) << 32) | (b + IV1);
		if (top <= c_job.target64) {
			const uint32_t slot = atomicAdd(&res[0], 1u);
			if (slot < CHC_MAX_RES) res[1 + slot] = n;
		}
	}
}

static uint32_t *g_res[CHC_MAX_DEV];
static int g_grid[CHC_MAX_DEV];

cudaError_t chc_init(int dev, int *grid)
{
	if (dev < 0 || dev >= CHC_MAX_DEV) return cudaErrorInvalidDevice;
	cudaDeviceProp prop;
	cudaError_t e = cudaGetDeviceProperties(&prop, dev);
	if (e != cudaSuccess) return e;
	int bps = 0;
	e = cudaOccupancyMaxActiveBlocksPerMultiprocessor(&bps, (const void *)k_chc, CHC_TPB, 0);
	if (e != cudaSuccess) return e;
	if (bps <= 0) bps = 1;
	g_grid[dev] = prop.multiProcessorCount * bps * 4;
	if (!g_res[dev]) {
		e = cudaMalloc(&g_res[dev], sizeof(uint32_t) * (1 + CHC_MAX_RES));
		if (e != cudaSuccess) return e;
	}
	*grid = g_grid[dev];
	return cudaSuccess;
}

void chc_free(int dev)
{
	if (dev < 0 || dev >= CHC_MAX_DEV) return;
	if (g_res[dev]) cudaFree(g_res[dev]);
	g_res[dev] = NULL;
}

cudaError_t chc_set_job(int dev, const uint8_t header[80], uint64_t target64)
{
	(void)dev;
	chc_job_t J;
	static const uint32_t iv[8] = {IV0, IV1, IV2, IV3, IV4, IV5, IV6, IV7};
	/* midstate: full compression of header bytes 0..63 */
	uint32_t W[64];
	for (int i = 0; i < 16; i++) W[i] = be32(header + 4 * i);
	for (int i = 16; i < 64; i++) W[i] = s1(W[i - 2]) + W[i - 7] + s0(W[i - 15]) + W[i - 16];
	uint32_t a = iv[0], b = iv[1], c = iv[2], d = iv[3], e = iv[4], f = iv[5], g = iv[6], h = iv[7];
	for (int i = 0; i < 64; i++) {
		const uint32_t t1 = h + S1(e) + CH(e, f, g) + h_K[i] + W[i];
		const uint32_t t2 = S0(a) + MAJ(a, b, c);
		h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	J.mid[0] = iv[0] + a; J.mid[1] = iv[1] + b; J.mid[2] = iv[2] + c; J.mid[3] = iv[3] + d;
	J.mid[4] = iv[4] + e; J.mid[5] = iv[5] + f; J.mid[6] = iv[6] + g; J.mid[7] = iv[7] + h;
	/* rounds 0..2 of the second block */
	J.w0 = be32(header + 64); J.w1 = be32(header + 68); J.w2 = be32(header + 72);
	const uint32_t w3[3] = {J.w0, J.w1, J.w2};
	a = J.mid[0]; b = J.mid[1]; c = J.mid[2]; d = J.mid[3]; e = J.mid[4]; f = J.mid[5]; g = J.mid[6]; h = J.mid[7];
	for (int i = 0; i < 3; i++) {
		const uint32_t t1 = h + S1(e) + CH(e, f, g) + h_K[i] + w3[i];
		const uint32_t t2 = S0(a) + MAJ(a, b, c);
		h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	/* the kernel continues with the RND() rotation of the reference code: after 3 rounds the variable called "a"
	 * in round 0's argument order holds the value of position (3 - 0) mod 8, etc. Store them in kernel order:
	 * kernel round 3 is RND(f, g, h, a, b, c, d, e) = positions (a..h of the textbook state) mapped as below. */
	J.st[5] = a; J.st[6] = b; J.st[7] = c; J.st[0] = d; J.st[1] = e; J.st[2] = f; J.st[3] = g; J.st[4] = h;
	J.target64 = target64;
	return cudaMemcpyToSymbol(c_job, &J, sizeof(J));
}

cudaError_t chc_scan(int dev, uint32_t start, uint32_t npt, uint32_t res[1 + CHC_MAX_RES])
{
	if (dev < 0 || dev >= CHC_MAX_DEV || !g_res[dev]) return cudaErrorInvalidValue;
	cudaError_t e = cudaMemsetAsync(g_res[dev], 0, sizeof(uint32_t));
	if (e != cudaSuccess) return e;
	k_chc<<<g_grid[dev], CHC_TPB>>>(start, npt, g_res[dev]);
	e = cudaGetLastError();
	if (e != cudaSuccess) return e;
	return cudaMemcpy(res, g_res[dev], sizeof(uint32_t) * (1 + CHC_MAX_RES), cudaMemcpyDeviceToHost);
}
