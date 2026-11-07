/*
 * lyra2v2_gpu.cu - Crypto Connection Miner driver of the lyra2v2 kernels of this folder (from MYMINER / ccminer 2.3.1,
 * GPL-3, see COPYING-ccminer-GPL3.txt). Same call sequence as ccminer's scanhash_lyra2v2 (lyra2/lyra2REv2.cu).
 */
#include <stdio.h>
#include <string.h>
#include "cuda_helper.h"
#include "lyra2v2_gpu.h"

extern void blake256_cpu_init(int thr_id, uint32_t threads);
extern void blake256_cpu_setBlock_80(uint32_t *pdata);
extern void blakeKeccak256_cpu_hash_80(const int thr_id, const uint32_t threads, const uint32_t startNonce, uint64_t *Hash, int order);
extern void skein256_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNonce, uint64_t *d_outputHash, int order);
extern void skein256_cpu_init(int thr_id, uint32_t threads);
extern void cubehash256_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNounce, uint64_t *d_hash, int order);
extern void lyra2v2_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNonce, uint64_t *d_outputHash, int order);
extern void lyra2v2_cpu_init(int thr_id, uint32_t threads, uint64_t *d_matrix);
extern void bmw256_setTarget(const void *ptarget);
extern void bmw256_cpu_init(int thr_id, uint32_t threads);
extern void bmw256_cpu_free(int thr_id);
extern void bmw256_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNounce, uint64_t *g_hash, uint32_t *resultnonces);

struct l2_state {
	bool init;
	uint32_t throughput;
	uint64_t *d_hash;
	uint64_t *d_matrix;
};
static l2_state g_l2[MAX_GPUS];

cudaError_t l2_init(int dev, uint32_t throughput)
{
	if (dev < 0 || dev >= MAX_GPUS) return cudaErrorInvalidDevice;
	l2_free(dev);
	cudaDeviceProp p;
	cudaError_t e = cudaGetDeviceProperties(&p, dev);
	if (e != cudaSuccess) return e;
	device_sm[dev] = p.major * 100 + p.minor * 10;
	device_mpcount[dev] = (short)p.multiProcessorCount;
	if (device_sm[dev] < 500) return cudaErrorInvalidDeviceFunction;   /* Maxwell and later only */
	throughput &= ~255u;
	if (throughput < 256) throughput = 256;
	blake256_cpu_init(dev, throughput);
	skein256_cpu_init(dev, throughput);
	bmw256_cpu_init(dev, throughput);
	cuda_get_arch(dev);
	/* sm >= 5.0: the Lyra2 matrix lives in shared memory, 128 bytes per hash in global memory (MYMINER) */
	const size_t matrix_sz = 16 * sizeof(uint64_t);
	e = cudaMalloc(&g_l2[dev].d_matrix, matrix_sz * (((size_t)throughput + 31) & ~(size_t)31));
	if (e != cudaSuccess) return e;
	lyra2v2_cpu_init(dev, throughput, g_l2[dev].d_matrix);
	e = cudaMalloc(&g_l2[dev].d_hash, (size_t)32 * throughput);
	if (e != cudaSuccess) { cudaFree(g_l2[dev].d_matrix); g_l2[dev].d_matrix = NULL; return e; }
	g_l2[dev].throughput = throughput;
	g_l2[dev].init = true;
	return cudaGetLastError();
}

void l2_free(int dev)
{
	if (dev < 0 || dev >= MAX_GPUS || !g_l2[dev].init) return;
	cudaFree(g_l2[dev].d_hash);
	cudaFree(g_l2[dev].d_matrix);
	bmw256_cpu_free(dev);
	g_l2[dev].d_hash = g_l2[dev].d_matrix = NULL;
	g_l2[dev].init = false;
}

uint32_t l2_throughput(int dev)
{
	return (dev >= 0 && dev < MAX_GPUS && g_l2[dev].init) ? g_l2[dev].throughput : 0;
}

cudaError_t l2_set_job(int dev, const uint8_t header[80], const uint8_t target_le[32])
{
	if (dev < 0 || dev >= MAX_GPUS || !g_l2[dev].init) return cudaErrorNotReady;
	/* ccminer work data: 32-bit words read big-endian from the header bytes (BLAKE message words) */
	uint32_t pdata[20];
	for (int k = 0; k < 20; k++)
		pdata[k] = ((uint32_t)header[4 * k] << 24) | ((uint32_t)header[4 * k + 1] << 16) | ((uint32_t)header[4 * k + 2] << 8) | header[4 * k + 3];
	uint32_t ptarget[8];
	for (int k = 0; k < 8; k++)
		ptarget[k] = (uint32_t)target_le[4 * k] | ((uint32_t)target_le[4 * k + 1] << 8) | ((uint32_t)target_le[4 * k + 2] << 16) |
		             ((uint32_t)target_le[4 * k + 3] << 24);
	blake256_cpu_setBlock_80(pdata);
	bmw256_setTarget(ptarget);
	return cudaGetLastError();
}

cudaError_t l2_scan(int dev, uint32_t start, uint32_t found[2])
{
	found[0] = found[1] = 0;
	if (dev < 0 || dev >= MAX_GPUS || !g_l2[dev].init) return cudaErrorNotReady;
	const uint32_t thr = g_l2[dev].throughput;
	uint64_t *h = g_l2[dev].d_hash;
	int order = 0;
	blakeKeccak256_cpu_hash_80(dev, thr, start, h, order++);
	cubehash256_cpu_hash_32(dev, thr, start, h, order++);
	lyra2v2_cpu_hash_32(dev, thr, start, h, order++);
	skein256_cpu_hash_32(dev, thr, start, h, order++);
	cubehash256_cpu_hash_32(dev, thr, start, h, order++);
	bmw256_cpu_hash_32(dev, thr, start, h, found);   /* synchronous: copies the result back */
	cudaError_t e = cudaGetLastError();
	if (e == cudaSuccess) e = cudaDeviceSynchronize();
	return e;
}
