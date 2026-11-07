/*
 * hash_hex.c - prints the GOSTcoin hashes of hex data given on the command line (consensus code src/gost_ref.c):
 *   gost512(x), gostd(x) = gost256(gost512(x)) as computed, and gostd reversed (uint256 display order).
 *   Used to check the byte order of transaction ids and merkle nodes against the wallet.
 *   Build / run: tests\run_hash_hex.bat <hex> [<hex> ...]   (log logs\hash_hex.log)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "gost_ref.h"

static int hexval(char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static void put(const char *label, const uint8_t *b, size_t n, int reversed)
{
	printf("%s ", label);
	for (size_t i = 0; i < n; i++) printf("%02x", b[reversed ? n - 1 - i : i]);
	printf("\n");
}

int main(int argc, char **argv)
{
	for (int a = 1; a < argc; a++) {
		const size_t hl = strlen(argv[a]);
		if (hl % 2) { printf("odd hex length\n"); return 1; }
		const size_t n = hl / 2;
		uint8_t *buf = (uint8_t *)malloc(n ? n : 1);
		for (size_t i = 0; i < n; i++) {
			const int x = hexval(argv[a][2 * i]), y = hexval(argv[a][2 * i + 1]);
			if (x < 0 || y < 0) { printf("bad hex\n"); return 1; }
			buf[i] = (uint8_t)(x * 16 + y);
		}
		uint8_t d512[64], d256[32];
		gost_ref_512(buf, n, d512);
		gost_ref_256(d512, 64, d256);
		printf("input %u bytes\n", (unsigned)n);
		put("gost512           ", d512, 64, 0);
		put("gostd             ", d256, 32, 0);
		put("gostd reversed    ", d256, 32, 1);
		if (n == 80) {
			uint8_t h[32];
			gostd_ref(buf, h);
			put("gostd_ref(header) ", h, 32, 0);
		}
		free(buf);
	}
	return 0;
}
