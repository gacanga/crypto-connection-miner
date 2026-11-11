/* ethash_gpu.cu - Crypto Connection Miner: Ethash on NVIDIA GPUs (NEX Chain, NEXC; since 0.9.0). See ethash_gpu.h.
 * Written for this miner from the Ethash specification; the search kernel uses the "8 threads per hash" layout of
 * the ethminer CUDA kernel (one coalesced 128-byte load per DAG access).
 *
 * DAG generation: one thread per 64-byte dataset item:
 *   mix = cache[i % n] with word 0 ^= i, keccak512; 256 rounds mix = fnv(mix, cache[fnv(i ^ j, mix[j % 16]) % n]);
 *   item = keccak512(mix).
 * Search: s = keccak512(header || nonce LE) per thread; then the 8 threads of a group compute the 8 hashes of the
 *   group one after the other (PAR at a time): thread t holds words 4t..4t+3 of the 128-byte mix, loads 16 bytes of
 *   every page; the page index of access a comes from mix word a % 32, held by thread (a % 32) / 4 (shuffle).
 *   Compressed mix word t = fnv reduction of thread t's 4 words; result = keccak256(s || compressed mix).
 */
#include "ethash_gpu.h"
#include <stdio.h>
#include <string.h>

#define ETH_MAX_DEV 16
#define FNV_PRIME 0x01000193u
#define PAR 4                 /* hashes of a group computed together (instruction-level parallelism) */

__constant__ uint64_t c_header[4];
__constant__ uint64_t c_target;

struct eth_dev_state {
	unsigned long long *d_res = nullptr;
	uint4 *d_dag = nullptr;
	uint64_t dag_bytes = 0;
	uint32_t pages = 0;
	int epoch = -1;
};
static eth_dev_state g_eds[ETH_MAX_DEV];

/* ------------------------------------------------------------------------------------------------ Keccak-f[1600] */
__device__ __forceinline__ uint64_t rotl64(const uint64_t x, const int n)
{
	return (x << n) | (x >> (64 - n));
}

__device__ __forceinline__ void keccakf(uint64_t s[25])
{
	const uint64_t RC[24] = {
		0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL, 0x8000000080008000ULL,
		0x000000000000808bULL, 0x0000000080000001ULL, 0x8000000080008081ULL, 0x8000000000008009ULL,
		0x000000000000008aULL, 0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
		0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL, 0x8000000000008003ULL,
		0x8000000000008002ULL, 0x8000000000000080ULL, 0x000000000000800aULL, 0x800000008000000aULL,
		0x8000000080008081ULL, 0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL};
	const int ROTC[24] = {1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44};
	const int PILN[24] = {10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1};
#pragma unroll
	for (int r = 0; r < 24; r++) {
		uint64_t bc[5], t;
		/* theta */
#pragma unroll
		for (int i = 0; i < 5; i++) bc[i] = s[i] ^ s[i + 5] ^ s[i + 10] ^ s[i + 15] ^ s[i + 20];
#pragma unroll
		for (int i = 0; i < 5; i++) {
			t = bc[(i + 4) % 5] ^ rotl64(bc[(i + 1) % 5], 1);
#pragma unroll
			for (int j = 0; j < 25; j += 5) s[j + i] ^= t;
		}
		/* rho and pi */
		t = s[1];
#pragma unroll
		for (int i = 0; i < 24; i++) {
			const int j = PILN[i];
			const uint64_t b = s[j];
			s[j] = rotl64(t, ROTC[i]);
			t = b;
		}
		/* chi */
#pragma unroll
		for (int j = 0; j < 25; j += 5) {
#pragma unroll
			for (int i = 0; i < 5; i++) bc[i] = s[j + i];
#pragma unroll
			for (int i = 0; i < 5; i++) s[j + i] ^= (~bc[(i + 1) % 5]) & bc[(i + 2) % 5];
		}
		/* iota */
		s[0] ^= RC[r];
	}
}

__device__ __forceinline__ uint32_t fnv(const uint32_t a, const uint32_t b)
{
	return a * FNV_PRIME ^ b;
}

__device__ __forceinline__ uint4 fnv4(const uint4 a, const uint4 b)
{
	return make_uint4(fnv(a.x, b.x), fnv(a.y, b.y), fnv(a.z, b.z), fnv(a.w, b.w));
}

/* keccak512 of 64 bytes held as 16 little-endian words, in place */
__device__ __forceinline__ void keccak512_64(uint32_t m[16])
{
	uint64_t s[25];
#pragma unroll
	for (int k = 0; k < 8; k++) s[k] = (uint64_t)m[2 * k] | ((uint64_t)m[2 * k + 1] << 32);
	s[8] = 0x8000000000000001ULL;   /* padding byte 0x01 at offset 64, 0x80 at offset 71 (rate 72 bytes) */
#pragma unroll
	for (int k = 9; k < 25; k++) s[k] = 0;
	keccakf(s);
#pragma unroll
	for (int k = 0; k < 8; k++) { m[2 * k] = (uint32_t)s[k]; m[2 * k + 1] = (uint32_t)(s[k] >> 32); }
}

/* ------------------------------------------------------------------------------------------------ DAG generation */
__global__ void __launch_bounds__(256) eth_dag_kernel(uint4 *__restrict__ dag, const uint4 *__restrict__ cache,
                                                       const uint32_t cache_nodes, const uint32_t start,
                                                       const uint32_t total_nodes)
{
	const uint32_t i = start + blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= total_nodes) return;
	uint32_t mix[16];
	{
		const uint4 *c = cache + (size_t)(i % cache_nodes) * 4;
#pragma unroll
		for (int q = 0; q < 4; q++) {
			const uint4 v = __ldg(c + q);
			mix[4 * q] = v.x; mix[4 * q + 1] = v.y; mix[4 * q + 2] = v.z; mix[4 * q + 3] = v.w;
		}
	}
	mix[0] ^= i;
	keccak512_64(mix);
	for (uint32_t jj = 0; jj < 256; jj += 16) {
#pragma unroll
		for (int k = 0; k < 16; k++) {
			const uint32_t parent = fnv(i ^ (jj + k), mix[k]) % cache_nodes;
			const uint4 *p = cache + (size_t)parent * 4;
#pragma unroll
			for (int q = 0; q < 4; q++) {
				const uint4 v = __ldg(p + q);
				mix[4 * q] = fnv(mix[4 * q], v.x);
				mix[4 * q + 1] = fnv(mix[4 * q + 1], v.y);
				mix[4 * q + 2] = fnv(mix[4 * q + 2], v.z);
				mix[4 * q + 3] = fnv(mix[4 * q + 3], v.w);
			}
		}
	}
	keccak512_64(mix);
	uint4 *o = dag + (size_t)i * 4;
#pragma unroll
	for (int q = 0; q < 4; q++) o[q] = make_uint4(mix[4 * q], mix[4 * q + 1], mix[4 * q + 2], mix[4 * q + 3]);
}

/* ------------------------------------------------------------------------------------------------ search */
__device__ __forceinline__ uint64_t shfl64(const uint64_t v, const int src)
{
	const uint32_t lo = __shfl_sync(0xffffffffu, (uint32_t)v, src, 8);
	const uint32_t hi = __shfl_sync(0xffffffffu, (uint32_t)(v >> 32), src, 8);
	return (uint64_t)lo | ((uint64_t)hi << 32);
}

__device__ __forceinline__ uint32_t mixword(const uint4 m, const int b)
{
	return b == 0 ? m.x : b == 1 ? m.y : b == 2 ? m.z : m.w;
}

__global__ void __launch_bounds__(ETH_TPB) eth_search_kernel(const uint4 *__restrict__ dag, const uint32_t pages,
                                                              const uint64_t start, unsigned long long *__restrict__ res)
{
	const uint64_t nonce = start + blockIdx.x * blockDim.x + threadIdx.x;
	const int lane = threadIdx.x & 7;
	const int mix_idx = lane & 3;

	/* s = keccak512(header || nonce): 40 bytes, rate 72 */
	uint64_t s[25];
	s[0] = c_header[0]; s[1] = c_header[1]; s[2] = c_header[2]; s[3] = c_header[3];
	s[4] = nonce;
	s[5] = 0x01ULL;
#pragma unroll
	for (int k = 6; k < 25; k++) s[k] = 0;
	s[8] = 0x8000000000000000ULL;
	keccakf(s);
	uint64_t sh[8];
#pragma unroll
	for (int k = 0; k < 8; k++) sh[k] = s[k];

	uint64_t cm[4] = {0, 0, 0, 0};   /* compressed mix of this thread's hash */
#pragma unroll
	for (int i = 0; i < 8; i += PAR) {
		uint4 mix[PAR];
		uint32_t init0[PAR];
#pragma unroll
		for (int p = 0; p < PAR; p++) {
			/* the hash of thread i + p: its s words 2*mix_idx, 2*mix_idx+1 (mix = s twice) */
			uint64_t a = 0, b = 0, s0;
#pragma unroll
			for (int q = 0; q < 4; q++) {
				const uint64_t x = shfl64(sh[2 * q], i + p);
				const uint64_t y = shfl64(sh[2 * q + 1], i + p);
				if (q == mix_idx) { a = x; b = y; }
				if (q == 0) s0 = x;
			}
			mix[p] = make_uint4((uint32_t)a, (uint32_t)(a >> 32), (uint32_t)b, (uint32_t)(b >> 32));
			init0[p] = (uint32_t)s0;
		}
#pragma unroll 4
		for (uint32_t a = 0; a < 64; a += 4) {
			const int t = (int)((a >> 2) & 7);
#pragma unroll
			for (int b = 0; b < 4; b++) {
				uint32_t off[PAR];
#pragma unroll
				for (int p = 0; p < PAR; p++) {
					off[p] = fnv(init0[p] ^ (a + b), mixword(mix[p], b)) % pages;
					off[p] = __shfl_sync(0xffffffffu, off[p], t, 8);
				}
#pragma unroll
				for (int p = 0; p < PAR; p++) mix[p] = fnv4(mix[p], __ldg(dag + (size_t)off[p] * 8 + lane));
			}
		}
#pragma unroll
		for (int p = 0; p < PAR; p++) {
			const uint32_t tm = fnv(fnv(fnv(mix[p].x, mix[p].y), mix[p].z), mix[p].w);
			uint32_t w[8];
#pragma unroll
			for (int k = 0; k < 8; k++) w[k] = __shfl_sync(0xffffffffu, tm, k, 8);
			if (lane == i + p) {
#pragma unroll
				for (int k = 0; k < 4; k++) cm[k] = (uint64_t)w[2 * k] | ((uint64_t)w[2 * k + 1] << 32);
			}
		}
	}

	/* result = keccak256(s || compressed mix): 96 bytes, rate 136 */
#pragma unroll
	for (int k = 0; k < 8; k++) s[k] = sh[k];
	s[8] = cm[0]; s[9] = cm[1]; s[10] = cm[2]; s[11] = cm[3];
	s[12] = 0x01ULL;
#pragma unroll
	for (int k = 13; k < 25; k++) s[k] = 0;
	s[16] = 0x8000000000000000ULL;
	keccakf(s);
	/* first 8 bytes of the result, read big-endian */
	const uint64_t top = __byte_perm((uint32_t)(s[0] >> 32), 0, 0x0123) | ((uint64_t)__byte_perm((uint32_t)s[0], 0, 0x0123) << 32);
	if (top <= c_target) {
		const unsigned long long k = atomicAdd(&res[0], 1ULL);
		if (k < ETH_MAX_RES) res[1 + k] = nonce;
	}
}

/* ------------------------------------------------------------------------------------------------ host */
cudaError_t eth_init(int dev, uint32_t *batch)
{
	if (dev < 0 || dev >= ETH_MAX_DEV) return cudaErrorInvalidDevice;
	eth_dev_state &st = g_eds[dev];
	cudaDeviceProp prop;
	cudaError_t e = cudaGetDeviceProperties(&prop, dev);
	if (e != cudaSuccess) return e;
	if (!st.d_res) {
		e = cudaMalloc(&st.d_res, sizeof(unsigned long long) * (1 + ETH_MAX_RES));
		if (e != cudaSuccess) return e;
	}
	/* about 2^16 hashes per SM per launch to start with; the host adapts the batch to ~150 ms per launch */
	*batch = (uint32_t)prop.multiProcessorCount * 65536u;
	return cudaSuccess;
}

void eth_free(int dev)
{
	if (dev < 0 || dev >= ETH_MAX_DEV) return;
	eth_dev_state &st = g_eds[dev];
	if (st.d_res) cudaFree(st.d_res);
	if (st.d_dag) cudaFree(st.d_dag);
	st = eth_dev_state();
}

int eth_dag_epoch(int dev)
{
	return (dev >= 0 && dev < ETH_MAX_DEV) ? g_eds[dev].epoch : -1;
}

cudaError_t eth_make_dag(int dev, uint32_t epoch, const uint8_t *cache, uint64_t cache_bytes, uint64_t dag_bytes,
                         void (*progress)(int dev, int percent))
{
	if (dev < 0 || dev >= ETH_MAX_DEV) return cudaErrorInvalidDevice;
	eth_dev_state &st = g_eds[dev];
	if (st.d_dag && st.epoch == (int)epoch && st.dag_bytes == dag_bytes) return cudaSuccess;
	if (st.d_dag) { cudaFree(st.d_dag); st.d_dag = nullptr; }
	st.epoch = -1;
	st.dag_bytes = 0;
	st.pages = 0;
	cudaError_t e = cudaMalloc(&st.d_dag, (size_t)dag_bytes);
	if (e != cudaSuccess) { st.d_dag = nullptr; return e; }
	uint4 *d_cache = nullptr;
	e = cudaMalloc(&d_cache, (size_t)cache_bytes);
	if (e != cudaSuccess) return e;
	e = cudaMemcpy(d_cache, cache, (size_t)cache_bytes, cudaMemcpyHostToDevice);
	if (e != cudaSuccess) { cudaFree(d_cache); return e; }
	const uint32_t nodes = (uint32_t)(dag_bytes / 64);
	const uint32_t cache_nodes = (uint32_t)(cache_bytes / 64);
	const uint32_t chunk = 1u << 18;   /* items per launch: well below the Windows watchdog */
	int last = -1;
	for (uint32_t start = 0; start < nodes; start += chunk) {
		const uint32_t n = nodes - start < chunk ? nodes - start : chunk;
		eth_dag_kernel<<<(n + 255) / 256, 256>>>(st.d_dag, d_cache, cache_nodes, start, nodes);
		e = cudaDeviceSynchronize();
		if (e == cudaSuccess) e = cudaGetLastError();
		if (e != cudaSuccess) { cudaFree(d_cache); return e; }
		const int pct = (int)((uint64_t)(start + n) * 100 / nodes);
		if (progress && pct / 25 != last / 25) { progress(dev, pct); last = pct; }
	}
	cudaFree(d_cache);
	st.epoch = (int)epoch;
	st.dag_bytes = dag_bytes;
	st.pages = (uint32_t)(dag_bytes / 128);
	return cudaSuccess;
}

cudaError_t eth_set_job(int dev, const uint8_t header[32], uint64_t target64)
{
	(void)dev;
	uint64_t h[4];
	for (int k = 0; k < 4; k++) {
		uint64_t v = 0;
		for (int b = 7; b >= 0; b--) v = (v << 8) | header[8 * k + b];
		h[k] = v;
	}
	cudaError_t e = cudaMemcpyToSymbol(c_header, h, sizeof(h));
	if (e != cudaSuccess) return e;
	return cudaMemcpyToSymbol(c_target, &target64, sizeof(target64));
}

cudaError_t eth_scan(int dev, uint64_t start, uint32_t count, uint64_t res[1 + ETH_MAX_RES])
{
	if (dev < 0 || dev >= ETH_MAX_DEV) return cudaErrorInvalidDevice;
	eth_dev_state &st = g_eds[dev];
	if (!st.d_dag || !st.d_res) return cudaErrorNotReady;
	cudaError_t e = cudaMemset(st.d_res, 0, sizeof(unsigned long long));
	if (e != cudaSuccess) return e;
	const uint32_t blocks = count / ETH_TPB;
	eth_search_kernel<<<blocks, ETH_TPB>>>(st.d_dag, st.pages, start, st.d_res);
	e = cudaGetLastError();
	if (e != cudaSuccess) return e;
	unsigned long long r[1 + ETH_MAX_RES];
	e = cudaMemcpy(r, st.d_res, sizeof(r), cudaMemcpyDeviceToHost);
	if (e != cudaSuccess) return e;
	for (int k = 0; k <= ETH_MAX_RES; k++) res[k] = (uint64_t)r[k];
	return cudaSuccess;
}
