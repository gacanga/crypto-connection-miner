/* chc_cpu.h - Crypto Connection Miner: Chipcoin proof of work on the CPU (CHC; since 0.10.1).
 * Chipcoin (github.com/chipcoin-protocol/chipcoin), consensus/pow.py: hash = SHA-256(SHA-256(80-byte Bitcoin-style
 * header)), the digest read as a BIG-endian integer (hashes.py hash_to_int): the FIRST digest bytes must be zero.
 * A standard sha256d CPU miner compares the digest as a little-endian number and therefore looks for the wrong nonces.
 * The first 64 header bytes are hashed once per job (midstate); each nonce then costs two SHA-256 compressions.
 * Three code paths, chosen at run time: Intel SHA extensions (SHA-NI: AMD Zen and later, Intel Ice Lake / Goldmont /
 * Alder Lake and later), AVX2 eight nonces at a time, portable C. */
#ifndef GM_CHC_CPU_H
#define GM_CHC_CPU_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

enum { CHC_CPU_SCALAR = 0, CHC_CPU_AVX2 = 1, CHC_CPU_SHANI = 2 };

typedef struct {
	uint32_t mid[8];    /* SHA-256 state after the first 64 header bytes */
	uint32_t tail[3];   /* big-endian words of header bytes 64..75 (merkle root tail, time, bits) */
} chc_cpu_job;

/* best code path of this CPU (CHC_CPU_SHANI, CHC_CPU_AVX2 or CHC_CPU_SCALAR) */
int chc_cpu_best_path(void);
/* 1 when this CPU (and its operating system) can run the given path */
int chc_cpu_supported(int path);
const char *chc_cpu_path_name(int path);
/* prepares a job from an 80-byte header (nonce bytes ignored) */
void chc_cpu_prepare(const uint8_t header[80], chc_cpu_job *job);
/* scans nonces first .. first + count - 1 (nonce = u32le of header bytes 76..79) with the given path; the nonces
 * whose digest bytes 0..7 (big-endian) are <= target64 go to out[] (at most max_out); returns how many were found */
uint32_t chc_cpu_scan(int path, const chc_cpu_job *job, uint32_t first, uint32_t count, uint64_t target64,
                      uint32_t *out, uint32_t max_out);

#ifdef __cplusplus
}
#endif
#endif
