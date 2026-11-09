/* neoscrypt_ref.h - CPU reference of NeoScrypt (src/neoscrypt/neoscrypt.c, John Doering's reference as shipped in
 * ccminer, BSD 2-clause). Profile 0x80000620 = N 128, r 2, Salsa20/20 + ChaCha20/20, FastKDF (Feathercoin).
 * output: 32 bytes, a little-endian uint256 (output[31] most significant) compared with the target. */
#ifndef GM_NEOSCRYPT_REF_H
#define GM_NEOSCRYPT_REF_H
#ifdef __cplusplus
extern "C" {
#endif
void neoscrypt(unsigned char *output, const unsigned char *input, unsigned int profile);
#ifdef __cplusplus
}
#endif
#define NEOSCRYPT_PROFILE 0x80000620U
#endif
