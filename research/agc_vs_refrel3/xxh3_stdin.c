/* xxh3_stdin.c - XXH3_64bits (xxHash 0.8, seed 0) of stdin, printed as %016llx (the form of the manifest's fasta_xxh3). */
#define XXH_INLINE_ALL
#include "xxhash.h"
#include <stdio.h>
int main(void) { static unsigned char b[1 << 22]; XXH3_state_t* s = XXH3_createState(); XXH3_64bits_reset(s); size_t n;
    while ((n = fread(b, 1, sizeof b, stdin)) > 0) XXH3_64bits_update(s, b, n);
    printf("%016llx\n", (unsigned long long)XXH3_64bits_digest(s)); XXH3_freeState(s); return 0; }
