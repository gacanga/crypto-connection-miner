/*
 * gostbench.cu - GostMiner development bench (GOSTcoin, algorithm gostd) for NVIDIA Pascal (P104-100, sm_61).
 *
 *   1. checks the GPU digests against the consensus reference (src/gost_ref.c) on random nonces,
 *   2. checks that every kernel variant finds exactly the expected nonces for an easy target,
 *   3. measures the hash rate of each variant: placement of the 64 table lookups of one LPS
 *      (shared memory or read-only cache, 64-bit mask, bit 8*j+i = output word j, table i)
 *      and launch configuration (threads per block, minimum blocks per SM).
 *
 * Usage: gostbench.exe [--gpu N] [--seconds S] [--repeat R] [--only-verify] [--filter TEXT]
 * Build: windows\build_bench.bat (CUDA 12.9, -arch=sm_61)
 */
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <vector>
#include <string>
#include <algorithm>
#include <chrono>

#include "gost_ref.h"
#include "gostd_core.h"

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
	fprintf(stderr, "CUDA error %s at %s:%d\n", cudaGetErrorString(e_), __FILE__, __LINE__); exit(2); } } while (0)

__device__ uint64_t d_T[8][256];
__constant__ gostd_job_t c_job;

/* table bank of the kernels: (word j, table i) in the mask -> __ldg, otherwise shared memory */
template <uint64_t MASK>
struct dev_tb {
	const uint64_t (*s)[256];
	__host__ __device__ __forceinline__ uint64_t t(int i, int j, uint32_t idx) const
	{
#ifdef __CUDA_ARCH__
		if ((MASK >> (8 * j + i)) & 1) return __ldg(&d_T[i][idx]);
		return s[i][idx];
#else
		(void)i; (void)j; (void)idx; return 0;
#endif
	}
};

#define MAX_RES 63

template <uint64_t MASK, int TPB, int MINB, bool SHSTASH>
__global__ void __launch_bounds__(TPB, MINB) k_search(uint32_t start, uint32_t npt, uint32_t *res)
{
	__shared__ uint64_t sT[8][256];
	__shared__ uint64_t sstash[SHSTASH ? 8 : 1][SHSTASH ? TPB : 1];
	uint64_t lstash[8];
	for (int k = threadIdx.x; k < 2048; k += TPB) sT[k >> 8][k & 255] = d_T[k >> 8][k & 255];
	__syncthreads();
	dev_tb<MASK> tb;
	tb.s = sT;
	uint64_t *stash = SHSTASH ? &sstash[0][threadIdx.x] : lstash;
	const int sstride = SHSTASH ? TPB : 1;
	const uint32_t stride = gridDim.x * TPB;
	uint32_t nonce = start + blockIdx.x * TPB + threadIdx.x;
	for (uint32_t it = 0; it < npt; it++, nonce += stride) {
		const uint64_t w0 = gostd_nonce<dev_tb<MASK>, false>(tb, c_job, nonce, 0, stash, sstride);
		if (gost_bswap64(w0) <= c_job.target) {
			const uint32_t slot = atomicAdd(&res[0], 1u);
			if (slot < MAX_RES) res[1 + slot] = nonce;
		}
	}
}

/* full digests of nonces start .. start + n - 1 (verification) */
__global__ void __launch_bounds__(256, 1) k_dump(uint32_t start, uint32_t n, uint64_t *out)
{
	__shared__ uint64_t sT[8][256];
	__shared__ uint64_t stash[8][256];
	for (int k = threadIdx.x; k < 2048; k += 256) sT[k >> 8][k & 255] = d_T[k >> 8][k & 255];
	__syncthreads();
	dev_tb<0> tb;
	tb.s = sT;
	const uint32_t i = blockIdx.x * 256 + threadIdx.x;
	if (i >= n) return;
	gostd_nonce<dev_tb<0>, true>(tb, c_job, start + i, out + 4 * (size_t)i, &stash[0][threadIdx.x], 256);
}

typedef void (*kfn_t)(uint32_t, uint32_t, uint32_t *);

struct variant {
	std::string name;
	kfn_t fn;
	int tpb;
	int minb;
	uint64_t mask;
};

/* masks: "rotK" = table i via __ldg for word j when (i + j) % 8 < K (each table K times out of 8),
 *        "fixK" = tables 0..K-1 via __ldg for every word,
 *        "orig" = GOSTSec ccminer gostd kernel, "maxw" = ccminer x11 streebog_maxwell kernel */
#define ROTMASK(K) ( \
	(((0+0)%8<(K))?1ULL:0)<<0 | (((1+0)%8<(K))?1ULL:0)<<1 | (((2+0)%8<(K))?1ULL:0)<<2 | (((3+0)%8<(K))?1ULL:0)<<3 | \
	(((4+0)%8<(K))?1ULL:0)<<4 | (((5+0)%8<(K))?1ULL:0)<<5 | (((6+0)%8<(K))?1ULL:0)<<6 | (((7+0)%8<(K))?1ULL:0)<<7 | \
	(((0+1)%8<(K))?1ULL:0)<<8 | (((1+1)%8<(K))?1ULL:0)<<9 | (((2+1)%8<(K))?1ULL:0)<<10 | (((3+1)%8<(K))?1ULL:0)<<11 | \
	(((4+1)%8<(K))?1ULL:0)<<12 | (((5+1)%8<(K))?1ULL:0)<<13 | (((6+1)%8<(K))?1ULL:0)<<14 | (((7+1)%8<(K))?1ULL:0)<<15 | \
	(((0+2)%8<(K))?1ULL:0)<<16 | (((1+2)%8<(K))?1ULL:0)<<17 | (((2+2)%8<(K))?1ULL:0)<<18 | (((3+2)%8<(K))?1ULL:0)<<19 | \
	(((4+2)%8<(K))?1ULL:0)<<20 | (((5+2)%8<(K))?1ULL:0)<<21 | (((6+2)%8<(K))?1ULL:0)<<22 | (((7+2)%8<(K))?1ULL:0)<<23 | \
	(((0+3)%8<(K))?1ULL:0)<<24 | (((1+3)%8<(K))?1ULL:0)<<25 | (((2+3)%8<(K))?1ULL:0)<<26 | (((3+3)%8<(K))?1ULL:0)<<27 | \
	(((4+3)%8<(K))?1ULL:0)<<28 | (((5+3)%8<(K))?1ULL:0)<<29 | (((6+3)%8<(K))?1ULL:0)<<30 | (((7+3)%8<(K))?1ULL:0)<<31 | \
	(((0+4)%8<(K))?1ULL:0)<<32 | (((1+4)%8<(K))?1ULL:0)<<33 | (((2+4)%8<(K))?1ULL:0)<<34 | (((3+4)%8<(K))?1ULL:0)<<35 | \
	(((4+4)%8<(K))?1ULL:0)<<36 | (((5+4)%8<(K))?1ULL:0)<<37 | (((6+4)%8<(K))?1ULL:0)<<38 | (((7+4)%8<(K))?1ULL:0)<<39 | \
	(((0+5)%8<(K))?1ULL:0)<<40 | (((1+5)%8<(K))?1ULL:0)<<41 | (((2+5)%8<(K))?1ULL:0)<<42 | (((3+5)%8<(K))?1ULL:0)<<43 | \
	(((4+5)%8<(K))?1ULL:0)<<44 | (((5+5)%8<(K))?1ULL:0)<<45 | (((6+5)%8<(K))?1ULL:0)<<46 | (((7+5)%8<(K))?1ULL:0)<<47 | \
	(((0+6)%8<(K))?1ULL:0)<<48 | (((1+6)%8<(K))?1ULL:0)<<49 | (((2+6)%8<(K))?1ULL:0)<<50 | (((3+6)%8<(K))?1ULL:0)<<51 | \
	(((4+6)%8<(K))?1ULL:0)<<52 | (((5+6)%8<(K))?1ULL:0)<<53 | (((6+6)%8<(K))?1ULL:0)<<54 | (((7+6)%8<(K))?1ULL:0)<<55 | \
	(((0+7)%8<(K))?1ULL:0)<<56 | (((1+7)%8<(K))?1ULL:0)<<57 | (((2+7)%8<(K))?1ULL:0)<<58 | (((3+7)%8<(K))?1ULL:0)<<59 | \
	(((4+7)%8<(K))?1ULL:0)<<60 | (((5+7)%8<(K))?1ULL:0)<<61 | (((6+7)%8<(K))?1ULL:0)<<62 | (((7+7)%8<(K))?1ULL:0)<<63 )

#define FIXW(K) ((uint64_t)((1u << (K)) - 1u))
#define FIXMASK(K) (FIXW(K) * 0x0101010101010101ULL)

/* GOSTSec gostd kernel: words 0-3 -> T0,T1,T3 ; words 4-7 -> T4,T6,T7 */
#define MASK_ORIG (0x0B0B0B0BULL | (0xD0D0D0D0ULL << 32))
/* ccminer streebog_maxwell (per word): w0 T0,T7 | w1 T0,T1,T7 | w2 T0,T1,T7 | w3 T0,T4,T7 |
 *                                     w4 T0,T2,T6,T7 | w5 T0,T1,T6,T7 | w6 T0,T6,T7 | w7 T0,T1,T6,T7 */
#define MASK_MAXW (0x81ULL | 0x83ULL << 8 | 0x83ULL << 16 | 0x91ULL << 24 | 0xC5ULL << 32 | 0xC3ULL << 40 | \
                   0xC1ULL << 48 | 0xC3ULL << 56)

#define V(NAME, MASK, TPB, MINB) { std::string(NAME) + " tpb" #TPB " minb" #MINB, k_search<(MASK), TPB, MINB, false>, TPB, MINB, (MASK) }
#define VS(NAME, MASK, TPB, MINB) { std::string(NAME) + " tpb" #TPB " minb" #MINB " shstash", k_search<(MASK), TPB, MINB, true>, TPB, MINB, (MASK) }

/* mixes: even output words with the rotK1 pattern, odd output words with the rotK2 pattern */
#define EVENW 0x00FF00FF00FF00FFULL
#define MIXMASK(K1, K2) ((ROTMASK(K1) & EVENW) | (ROTMASK(K2) & ~EVENW))

static std::vector<variant> all_variants()
{
	std::vector<variant> v = {
		/* round 3 (06/11): the shared-memory stash of the hash-512 digest did not help at minb3 (23.5 vs 25.5 MH/s),
		 * results are noisy (power limit 180 W?) -> A/B of the best candidates, with and without the stash */
		V("maxw", MASK_MAXW, 256, 3), VS("maxw", MASK_MAXW, 256, 3),
		V("mix34", MIXMASK(3, 4), 256, 3), VS("mix34", MIXMASK(3, 4), 256, 3),
		V("maxw", MASK_MAXW, 256, 4), VS("maxw", MASK_MAXW, 256, 4),
		V("orig", MASK_ORIG, 256, 3), V("maxw", MASK_MAXW, 256, 2),
	};
	return v;
}

static uint64_t rng_state = 0x243F6A8885A308D3ULL;
static uint64_t rnd64(void)
{
	rng_state ^= rng_state << 13; rng_state ^= rng_state >> 7; rng_state ^= rng_state << 17;
	return rng_state;
}

static void set_nonce(uint8_t *hdr, uint32_t n)
{
	hdr[76] = (uint8_t)n; hdr[77] = (uint8_t)(n >> 8); hdr[78] = (uint8_t)(n >> 16); hdr[79] = (uint8_t)(n >> 24);
}

static uint64_t load_le64(const uint8_t *p)
{
	uint64_t v = 0;
	for (int k = 7; k >= 0; k--) v = (v << 8) | p[k];
	return v;
}

int main(int argc, char **argv)
{
	int gpu = 0;
	double seconds = 4.0;
	bool only_verify = false;
	int repeat = 1;
	std::string filter;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--gpu") && i + 1 < argc) gpu = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
		else if (!strcmp(argv[i], "--only-verify")) only_verify = true;
		else if (!strcmp(argv[i], "--filter") && i + 1 < argc) filter = argv[++i];
		else if (!strcmp(argv[i], "--repeat") && i + 1 < argc) repeat = atoi(argv[++i]);
		else { fprintf(stderr, "usage: gostbench [--gpu N] [--seconds S] [--repeat R] [--only-verify] [--filter TEXT]\n"); return 1; }
	}
	CK(cudaSetDevice(gpu));
	cudaDeviceProp prop;
	CK(cudaGetDeviceProperties(&prop, gpu));
	printf("GPU %d: %s, %d SM, %.0f MHz, sm_%d%d\n", gpu, prop.name, prop.multiProcessorCount,
	       prop.clockRate / 1000.0, prop.major, prop.minor);

	const unsigned long long (*T)[256] = gost_ref_tables();
	const unsigned char (*C)[64] = gost_ref_constants();
	CK(cudaMemcpyToSymbol(d_T, T, sizeof(uint64_t) * 8 * 256));

	/* ---- 1. digests against the consensus reference ---- */
	int fails = 0;
	for (int hcase = 0; hcase < 4; hcase++) {
		uint8_t hdr[80];
		for (int i = 0; i < 80; i++) hdr[i] = (uint8_t)rnd64();
		if (hcase == 1) { hdr[0] = 0xFF; hdr[64] = 0xFF; }                 /* Sigma carry out of 128 bits */
		if (hcase == 2) { hdr[63] = 0xFF; hdr[0] = 0xFF; hdr[64] = 0xFF; } /* ... and through byte 47 */
		if (hcase == 3) { for (int i = 16; i < 76; i++) hdr[i] = 0xFF; }
		gostd_job_t J;
		gostd_prepare_job(&J, hdr, 0, T, C);
		CK(cudaMemcpyToSymbol(c_job, &J, sizeof(J)));
		const uint32_t n = 16384, start = (uint32_t)rnd64();
		uint64_t *d_out;
		CK(cudaMalloc(&d_out, 32 * (size_t)n));
		k_dump<<<n / 256, 256>>>(start, n, d_out);
		CK(cudaGetLastError());
		std::vector<uint64_t> out(4 * (size_t)n);
		CK(cudaMemcpy(out.data(), d_out, 32 * (size_t)n, cudaMemcpyDeviceToHost));
		CK(cudaFree(d_out));
		int bad = 0;
		for (uint32_t i = 0; i < n; i++) {
			uint8_t want[32];
			set_nonce(hdr, start + i);
			gostd_ref(hdr, want);
			for (int w = 0; w < 4; w++)
				if (out[4 * (size_t)i + w] != load_le64(want + 8 * w)) { bad++; break; }
		}
		printf("verify digests, header case %d: %u nonces, %d mismatches\n", hcase, n, bad);
		fails += bad;
	}
	if (fails) { printf("VERIFY FAILED\n"); return 3; }

	/* ---- 2. every variant finds the expected nonces for an easy target ---- */
	uint8_t hdr[80];
	for (int i = 0; i < 80; i++) hdr[i] = (uint8_t)rnd64();
	const uint64_t easy = 0x0000A00000000000ULL;   /* about 10 hits per 2^20 nonces */
	gostd_job_t J;
	gostd_prepare_job(&J, hdr, easy, T, C);
	CK(cudaMemcpyToSymbol(c_job, &J, sizeof(J)));
	const uint32_t vstart = 0x10000000u, vcount = 1u << 20;
	std::vector<uint32_t> expected;
	{
		uint64_t *d_out;
		CK(cudaMalloc(&d_out, 32 * (size_t)vcount));
		k_dump<<<vcount / 256, 256>>>(vstart, vcount, d_out);
		CK(cudaGetLastError());
		std::vector<uint64_t> out(4 * (size_t)vcount);
		CK(cudaMemcpy(out.data(), d_out, 32 * (size_t)vcount, cudaMemcpyDeviceToHost));
		CK(cudaFree(d_out));
		for (uint32_t i = 0; i < vcount; i++)
			if (gost_bswap64(out[4 * (size_t)i]) <= easy) expected.push_back(vstart + i);
		/* CPU check of the expected hits */
		for (uint32_t nn : expected) {
			uint8_t want[32];
			set_nonce(hdr, nn);
			gostd_ref(hdr, want);
			uint64_t be = 0;
			for (int k = 0; k < 8; k++) be = (be << 8) | want[k];
			if (be > easy) { printf("hit %08x does not validate on the CPU\n", nn); fails++; }
		}
	}
	printf("easy target: %zu expected hits in %u nonces\n", expected.size(), vcount);

	std::vector<variant> vars0 = all_variants(), vars;
	for (int r = 0; r < repeat; r++) vars.insert(vars.end(), vars0.begin(), vars0.end());
	uint32_t *d_res;
	CK(cudaMalloc(&d_res, sizeof(uint32_t) * (1 + MAX_RES)));
	for (auto &v : vars) {
		if (!filter.empty() && v.name.find(filter) == std::string::npos) continue;
		cudaFuncAttributes fa;
		CK(cudaFuncGetAttributes(&fa, (const void *)v.fn));
		int bps = 0;
		CK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&bps, (const void *)v.fn, v.tpb, 0));
		/* check */
		CK(cudaMemset(d_res, 0, sizeof(uint32_t) * (1 + MAX_RES)));
		const uint32_t grid = vcount / v.tpb / 16;
		v.fn<<<grid, v.tpb>>>(vstart, 16, d_res);
		CK(cudaGetLastError());
		uint32_t res[1 + MAX_RES];
		CK(cudaMemcpy(res, d_res, sizeof(res), cudaMemcpyDeviceToHost));
		std::vector<uint32_t> got(res + 1, res + 1 + std::min<uint32_t>(res[0], MAX_RES));
		std::sort(got.begin(), got.end());
		const bool ok = got == expected;
		if (!ok) fails++;
		double mhs = 0;
		if (!only_verify) {
			/* timing: about 0.2 s per launch, repeated for 'seconds' */
			gostd_prepare_job(&J, hdr, 0, T, C);   /* target 0: no result traffic */
			CK(cudaMemcpyToSymbol(c_job, &J, sizeof(J)));
			const uint32_t tgrid = prop.multiProcessorCount * std::max(bps, 1) * 8;
			uint32_t npt = 4;
			double total = 0, elapsed = 0;
			cudaEvent_t e0, e1;
			CK(cudaEventCreate(&e0)); CK(cudaEventCreate(&e1));
			uint32_t start = 0;
			while (elapsed < seconds) {
				CK(cudaEventRecord(e0));
				v.fn<<<tgrid, v.tpb>>>(start, npt, d_res);
				CK(cudaEventRecord(e1));
				CK(cudaEventSynchronize(e1));
				float ms = 0;
				CK(cudaEventElapsedTime(&ms, e0, e1));
				const double n = (double)tgrid * v.tpb * npt;
				start += (uint32_t)n;
				if (ms < 150 && npt < 4096) { npt *= 2; continue; }   /* warm-up / sizing launches not counted */
				total += n;
				elapsed += ms / 1000.0;
			}
			CK(cudaEventDestroy(e0)); CK(cudaEventDestroy(e1));
			mhs = total / elapsed / 1e6;
			gostd_prepare_job(&J, hdr, easy, T, C);
			CK(cudaMemcpyToSymbol(c_job, &J, sizeof(J)));
		}
		printf("%-24s regs %3d spill %4zu B  blocks/SM %d  check %s  %8.2f MH/s\n", v.name.c_str(), fa.numRegs,
		       (size_t)fa.localSizeBytes, bps, ok ? "OK  " : "FAIL", mhs);
		fflush(stdout);
	}
	CK(cudaFree(d_res));
	printf(fails ? "BENCH: %d FAILURE(S)\n" : "BENCH OK\n", fails);
	return fails ? 3 : 0;
}
