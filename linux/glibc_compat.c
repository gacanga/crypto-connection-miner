/* glibc_compat.c - Crypto Connection Miner (Linux, since 0.9.0): lets the binary run on glibc 2.34 and later although
 * it may be built against newer glibc headers. From glibc 2.38 the headers send strtol / strtoul / strtoull of C++ code
 * (g++ defines _GNU_SOURCE) to the C23 variants __isoc23_strtol / __isoc23_strtoul / __isoc23_strtoull, which glibc
 * 2.34-2.37 do not have. The C23 variants only add the "0b" binary prefix, never used by this miner, so they are
 * defined here on top of the classic functions (this file is compiled as C without _GNU_SOURCE, so its own calls are
 * not redirected). The binary is linked with gcc / g++ 11 (linux/build_linux.sh): their static libstdc++ / libgcc do
 * not need arc4random (glibc 2.36) nor _dl_find_object (glibc 2.35). */
#undef _GNU_SOURCE
#include <stdlib.h>

long __isoc23_strtol(const char *s, char **end, int base) { return strtol(s, end, base); }
unsigned long __isoc23_strtoul(const char *s, char **end, int base) { return strtoul(s, end, base); }
unsigned long long __isoc23_strtoull(const char *s, char **end, int base) { return strtoull(s, end, base); }
