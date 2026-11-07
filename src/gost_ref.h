/*
 * gost_ref.h - consensus reference of the GOSTcoin proof of work (CPU), see gost_ref.c
 */
#ifndef GOST_REF_H
#define GOST_REF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* GOST R 34.11-2012, 512-bit and 256-bit digests (byte order as in GOSTcoin / i2pd) */
void gost_ref_512(const uint8_t *buf, size_t len, uint8_t digest[64]);
void gost_ref_256(const uint8_t *buf, size_t len, uint8_t digest[32]);

/* GOSTcoin block proof of work: 256(512(header)), digest[0] is the most significant byte */
void gostd_ref(const uint8_t header[80], uint8_t digest[32]);

/* Streebog tables T[8][256] (64-bit LPS tables) and round constants C[12][64] */
const unsigned long long (*gost_ref_tables(void))[256];
const unsigned char (*gost_ref_constants(void))[64];

#ifdef __cplusplus
}
#endif

#endif
