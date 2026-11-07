/*
 * test_core.cpp - checks gpu/gostd_core.h (compiled for the CPU) against the consensus reference src/gost_ref.c
 *   random headers and nonces, plus headers that force the Sigma carries; full digest and word-0 paths.
 * Build: g++ -O2 -Isrc -Igpu tests/test_core.cpp src/gost_ref.c -o test_core   (gost_ref.c built as C++ is fine)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "gost_ref.h"
#include "gostd_core.h"

static uint64_t rng_state = 0x9E3779B97F4A7C15ULL;
static uint64_t rnd64(void)
{
	rng_state ^= rng_state << 13; rng_state ^= rng_state >> 7; rng_state ^= rng_state << 17;
	return rng_state;
}

int main(int argc, char **argv)
{
	const int headers = argc > 1 ? atoi(argv[1]) : 64;
	const int nonces = argc > 2 ? atoi(argv[2]) : 2000;
	const unsigned long long (*T)[256] = gost_ref_tables();
	const unsigned char (*C)[64] = gost_ref_constants();
	gost_host_tb tb;
	tb.T = T;
	long fails = 0, checked = 0, inc_carry = 0;

	for (int hi = 0; hi < headers; hi++) {
		uint8_t hdr[80];
		for (int i = 0; i < 80; i++) hdr[i] = (uint8_t)rnd64();
		/* edge cases: Sigma carries out of the 128-bit header part and through byte 47 */
		if (hi % 4 == 1) { hdr[0] = 0xFF; hdr[64] = 0xFF; }
		if (hi % 4 == 2) { hdr[63] = 0xFF; hdr[0] = 0xFF; hdr[64] = 0xFF; hdr[62] = 0xFF; }
		if (hi % 4 == 3) { for (int i = 16; i < 76; i++) hdr[i] = 0xFF; }
		gostd_job_t J;
		gostd_prepare_job(&J, hdr, 0, T, C);
		for (int n = 0; n < nonces; n++) {
			const uint32_t nonce = (n < 4) ? (uint32_t)(0xFFFFFFFFu - n) : (uint32_t)rnd64();
			hdr[76] = (uint8_t)nonce; hdr[77] = (uint8_t)(nonce >> 8);
			hdr[78] = (uint8_t)(nonce >> 16); hdr[79] = (uint8_t)(nonce >> 24);
			uint8_t want[32], h1[64];
			gostd_ref(hdr, want);
			gost_ref_512(hdr, 80, h1);
			if (h1[63] == 0xFF) inc_carry++;
			uint64_t full[4];
			uint64_t stash[8];
			const uint64_t w0f = gostd_nonce<gost_host_tb, true>(tb, J, nonce, full, stash, 1);
			const uint64_t w0 = gostd_nonce<gost_host_tb, false>(tb, J, nonce, 0, stash, 1);
			uint8_t got[32];
			for (int w = 0; w < 4; w++)
				for (int k = 0; k < 8; k++) got[8 * w + k] = (uint8_t)(full[w] >> (8 * k));
			const int ok = !memcmp(got, want, 32) && w0 == w0f && w0 == full[0];
			checked++;
			if (!ok) {
				if (fails < 5) {
					printf("MISMATCH header %d nonce %08x\n  ref ", hi, nonce);
					for (int i = 0; i < 32; i++) printf("%02x", want[i]);
					printf("\n  got ");
					for (int i = 0; i < 32; i++) printf("%02x", got[i]);
					printf("  w0 %016llx\n", (unsigned long long)w0);
				}
				fails++;
			}
		}
	}
	printf("checked %ld digests (%ld with a carry in the hash-256 Sigma), %ld mismatches\n", checked, inc_carry, fails);
	printf(fails ? "CORE TEST FAILED\n" : "CORE TEST OK\n");
	return fails != 0;
}
