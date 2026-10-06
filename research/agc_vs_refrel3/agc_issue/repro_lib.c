/* repro_lib.c - the same through the C API of libagc (AGC 3.2.4, src/lib-cxx/agc-api.h): agc_n_ctg of each set,
 * agc_get_ctg_len / agc_get_ctg_seq for a contig the source FASTA has and the archive lacks.
 * cc -O2 -I<agc-src>/src/lib-cxx repro_lib.c <agc-src>/bin/libagc.a <zstd> <libdeflate> <zlib-ng> <raduls> -lstdc++ -lpthread -lm
 * repro_lib <archive.agc> <set> <present contig> <missing contig> */
#include <stdio.h>
#include <stdlib.h>
#include "agc-api.h"
int main(int argc, char** argv) {
    if (argc != 5) return 1;
    agc_t* a = agc_open(argv[1], 0); if (!a) { printf("agc_open failed\n"); return 2; }
    printf("set %s: agc_n_ctg = %d\n", argv[2], agc_n_ctg(a, argv[2]));
    for (int k = 3; k <= 4; k++) { char buf[64] = {0};
        const int len = agc_get_ctg_len(a, argv[2], argv[k]);
        const int r = agc_get_ctg_seq(a, argv[2], argv[k], 0, 59, buf);
        printf("%s contig %s: agc_get_ctg_len = %d, agc_get_ctg_seq(0, 59) = %d%s%.60s\n", k == 3 ? "present" : "missing", argv[k], len, r, r > 0 ? " " : "", r > 0 ? buf : ""); }
    agc_close(a); return 0;
}
