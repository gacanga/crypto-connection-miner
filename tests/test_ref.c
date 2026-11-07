/*
 * test_ref.c - checks the consensus reference (gost_ref.c) against the GOSTcoin mainnet genesis block
 *   and the RFC 6986 / GOST R 34.11-2012 test vector M1.
 * Build: gcc -O2 -Isrc tests/test_ref.c src/gost_ref.c -o test_ref
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "gost_ref.h"

static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static int hex2bin(const char *hex, uint8_t *out, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		unsigned v;
		if (sscanf(hex + 2 * i, "%2x", &v) != 1) return -1;
		out[i] = (uint8_t)v;
	}
	return 0;
}

static void tohex(const uint8_t *b, size_t n, char *out)
{
	for (size_t i = 0; i < n; i++) sprintf(out + 2 * i, "%02x", b[i]);
}

int main(void)
{
	int fails = 0;
	char hex[200];

	/* GOSTcoin mainnet genesis (src/main.cpp): version 1, prev 0, merkle, time, bits, nonce */
	uint8_t hdr[80] = {0}, merkle_be[32], digest[32];
	put32(hdr, 1);
	hex2bin("1cf1e5211650ba5218b5b869c48c4bc480c4fd1bc849fdc1a81d68547b9f4d58", merkle_be, 32);
	for (int i = 0; i < 32; i++) hdr[36 + i] = merkle_be[31 - i];   /* uint256 is stored little-endian */
	put32(hdr + 68, 1491156549u);
	put32(hdr + 72, 0x1e0ffff0u);
	put32(hdr + 76, 517725659u);
	gostd_ref(hdr, digest);
	tohex(digest, 32, hex);
	const char *want = "00000dd00df9728558f339d2e034e2c862329d509018b56d699aec5b6fa6ba1f";
	printf("genesis : %s %s\n", hex, strcmp(hex, want) ? "FAIL" : "OK");
	fails += strcmp(hex, want) != 0;

	/* RFC 6986 example 1: M1 = "012345678901234567890123456789012345678901234567890123456789012" (63 bytes).
	 * The RFC writes numbers most significant byte first; this implementation takes the message bytes in
	 * that same order (big-endian), so M1 is fed reversed and the digest is compared reversed. */
	const char *m1 = "012345678901234567890123456789012345678901234567890123456789012";
	uint8_t msg[63], d512[64];
	for (int i = 0; i < 63; i++) msg[i] = (uint8_t)m1[62 - i];
	gost_ref_512(msg, 63, d512);
	uint8_t d512r[64];
	for (int i = 0; i < 64; i++) d512r[i] = d512[63 - i];
	tohex(d512r, 64, hex);
	const char *want512 = "1b54d01a4af5b9d5cc3d86d68d285462b19abc2475222f35c085122be4ba1ffa"
	                      "00ad30f8767b3a82384c6574f024c311e2a481332b08ef7f41797891c1646f48";
	printf("rfc M1  : %s\n          %s\n", hex, strcmp(hex, want512) ? "FAIL" : "OK");
	fails += strcmp(hex, want512) != 0;

	printf(fails ? "REF TEST FAILED\n" : "REF TEST OK\n");
	return fails != 0;
}
