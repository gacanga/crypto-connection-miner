/* lyra2ref.h - CPU reference of Lyra2REv2 (Vertcoin / Bitmark lyra2rev2), code of MiningCore's libmultihash
 * (src/lyra2ref: lyra2re2_only.c, Lyra2.c, Sponge.c and the sphlib hashes). Output: 32 bytes, little-endian uint256. */
#ifndef GM_LYRA2REF_H
#define GM_LYRA2REF_H
#ifdef __cplusplus
extern "C" {
#endif
void mc_lyra2re2_hash(const char *input80, char *output32);
#ifdef __cplusplus
}
#endif
#endif
