/*
 * neoscrypt_gpu.cu - Crypto Connection Miner driver of the NeoScrypt kernels of this folder (from ccminer 2.3.1 /
 * MYMINER, GPL-3, see gpu/lyra2v2/COPYING-ccminer-GPL3.txt). Same call sequence as ccminer's scanhash_neoscrypt
 * (neoscrypt/neoscrypt.cpp), in "getwork" byte order: the header words are passed as they are in memory (little-endian
 * 32-bit words of the header bytes) and the GPU writes the counter itself as the nonce word.
 */
#include <stdio.h>
#include <string.h>
#include "cuda_helper.h"
#include "neoscrypt_gpu.h"

extern cudaError_t neoscrypt_setBlockTarget(uint32_t* const data, uint32_t* const ptarget);
extern cudaError_t neoscrypt_init(int thr_id, uint32_t threads);
extern void neoscrypt_free(int thr_id);
extern cudaError_t neoscrypt_hash_k4(int thr_id, uint32_t threads, uint32_t startNounce, uint32_t *resNonces, bool stratum);

struct ns_state {
	bool init;
	uint32_t throughput;
};
static ns_state g_ns[MAX_GPUS];

cudaError_t ns_init(int dev, uint32_t throughput)
{
	if (dev < 0 || dev >= MAX_GPUS) return cudaErrorInvalidDevice;
	ns_free(dev);
	cudaDeviceProp p;
	cudaError_t e = cudaGetDeviceProperties(&p, dev);
	if (e != cudaSuccess) return e;
	device_sm[dev] = p.major * 100 + p.minor * 10;
	device_mpcount[dev] = (short)p.multiProcessorCount;
	if (device_sm[dev] < 500) return cudaErrorInvalidDeviceFunction;   /* Maxwell and later only */
	throughput &= ~63u;
	if (throughput < 64) throughput = 64;
	e = neoscrypt_init(dev, throughput);
	if (e != cudaSuccess) { neoscrypt_free(dev); return e; }
	g_ns[dev].throughput = throughput;
	g_ns[dev].init = true;
	return cudaGetLastError();
}

void ns_free(int dev)
{
	if (dev < 0 || dev >= MAX_GPUS || !g_ns[dev].init) return;
	neoscrypt_free(dev);
	g_ns[dev].init = false;
}

uint32_t ns_throughput(int dev)
{
	return (dev >= 0 && dev < MAX_GPUS && g_ns[dev].init) ? g_ns[dev].throughput : 0;
}

cudaError_t ns_set_job(int dev, const uint8_t header[80], const uint8_t target_le[32])
{
	if (dev < 0 || dev >= MAX_GPUS || !g_ns[dev].init) return cudaErrorNotReady;
	/* the kernel reads the first 64 bytes as one 64-byte vector: keep the words 64-byte aligned */
	alignas(64) uint32_t pdata[20];
	alignas(64) uint32_t ptarget[8];
	for (int k = 0; k < 20; k++)
		pdata[k] = (uint32_t)header[4 * k] | ((uint32_t)header[4 * k + 1] << 8) | ((uint32_t)header[4 * k + 2] << 16) |
		           ((uint32_t)header[4 * k + 3] << 24);
	for (int k = 0; k < 8; k++)
		ptarget[k] = (uint32_t)target_le[4 * k] | ((uint32_t)target_le[4 * k + 1] << 8) | ((uint32_t)target_le[4 * k + 2] << 16) |
		             ((uint32_t)target_le[4 * k + 3] << 24);
	return neoscrypt_setBlockTarget(pdata, ptarget);
}

cudaError_t ns_scan(int dev, uint32_t start, uint32_t *nonce, bool *hit)
{
	*hit = false;
	*nonce = 0;
	if (dev < 0 || dev >= MAX_GPUS || !g_ns[dev].init) return cudaErrorNotReady;
	uint32_t res[2] = { UINT32_MAX, UINT32_MAX };
	cudaError_t e = neoscrypt_hash_k4(dev, g_ns[dev].throughput, start, res, false);
	if (e != cudaSuccess) return e;
	/* UINT32_MAX = nothing found; a real hit on nonce 0xffffffff is lost (1 nonce in 2^32) */
	if (res[0] != UINT32_MAX) { *hit = true; *nonce = res[0]; }
	return cudaSuccess;
}
