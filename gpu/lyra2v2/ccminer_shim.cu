/*
 * ccminer_shim.cu - the few ccminer runtime symbols used by the lyra2v2 kernels of this folder
 * (taken from MYMINER, our ccminer 2.3.1 fork; GPL-3, see COPYING-ccminer-GPL3.txt).
 * Crypto Connection Miner uses "thread id" = CUDA device index, so device_map[i] = i.
 */
#include <cuda_runtime.h>
#include <stdint.h>
#include "cuda_helper.h"

extern "C" short device_map[MAX_GPUS] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
extern "C" long device_sm[MAX_GPUS] = { 0 };
extern "C" short device_mpcount[MAX_GPUS] = { 0 };
int cuda_arch[MAX_GPUS] = { 0 };

__global__ void gm_arch_probe(void) { }

/* architecture of the machine code that runs on the device (e.g. 610 for sm_61), as ccminer's cuda_get_arch */
int cuda_get_arch(int thr_id)
{
	const int dev_id = device_map[thr_id % MAX_GPUS];
	cudaFuncAttributes a;
	if (cudaFuncGetAttributes(&a, gm_arch_probe) == cudaSuccess) cuda_arch[dev_id] = a.binaryVersion * 10;
	else cuda_arch[dev_id] = (int)device_sm[dev_id];
	return cuda_arch[dev_id];
}

cudaError_t MyStreamSynchronize(cudaStream_t stream, int situation, int thr_id)
{
	(void)situation; (void)thr_id;
	return cudaStreamSynchronize(stream);
}

void cudaReportHardwareFailure(int thr_id, cudaError_t err, const char *func)
{
	(void)thr_id; (void)err; (void)func;
}
