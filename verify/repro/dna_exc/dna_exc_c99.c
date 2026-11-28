/* dna_exc_c99.c - claim head_dna_exc_reject, C99 part (2.6.6; c/aceapex_decode.c = python/csrc/aceapex_decode.c, the
 * Python package's decoder): the damaged archive of this directory (README.md) is refused by aceapex_decompress,
 * aceapex_decompress_region and aceapex_dec_open + aceapex_dec_region; the intact one decodes.
 *   default build:          damaged refused on 3 of 3, intact whole on 3 of 3   -> pass
 *   -DAX_DNA_EXC_NO_CHECK:  the control - the damaged archive returns the full size on 3 of 3
 * Prints: dna_exc_c99 <check|control> <pass|fail> <detail>. Usage: dna_exc_c99 <this directory> */
#include "aceapex_decode.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static unsigned char* slurp(const char* dir, const char* name, size_t* n) {
    char p[4096]; snprintf(p, sizeof p, "%s/%s", dir, name); FILE* f = fopen(p, "rb"); if (!f) return NULL;
    unsigned char* b = (unsigned char*)malloc(1 << 20); *n = fread(b, 1, 1 << 20, f); fclose(f); return b; }
static int full(const unsigned char* a, size_t na, uint64_t n, int ep) {
    unsigned char* d = (unsigned char*)malloc(n + 64); int64_t r = -1;
    if (ep == 0) r = aceapex_decompress(a, na, d, n);
    else if (ep == 1) r = aceapex_decompress_region(a, na, d, n, 0, n);
    else { aceapex_dec_t* h = aceapex_dec_open(a, na); if (h) { r = aceapex_dec_region(h, d, n, 0, n); aceapex_dec_close(h); } }
    free(d); return r < 0 ? 0 : r == (int64_t)n ? 1 : 2; }
int main(int argc, char** argv) {
#ifdef AX_DNA_EXC_NO_CHECK
    const int control = 1;
#else
    const int control = 0;
#endif
    size_t nb = 0, ng = 0; uint64_t n;
    unsigned char* bad = argc > 1 ? slurp(argv[1], "dna_exc_h3h4zero.aet", &nb) : NULL;
    unsigned char* good = argc > 1 ? slurp(argv[1], "dna_exc_intact.aet", &ng) : NULL;
    if (!bad || !good || nb < 20) { printf("dna_exc_c99\t%s\tfail\tinputs missing\n", control ? "control" : "check"); return 1; }
    memcpy(&n, bad + 12, 8);
    int br = 0, bw = 0, gw = 0;
    for (int ep = 0; ep < 3; ep++) { const int s = full(bad, nb, n, ep), t = full(good, ng, n, ep); if (s == 0) br++; if (s == 1) bw++; if (t == 1) gw++; }
    const int pass = gw == 3 && (control ? bw == 3 : br == 3);
    printf("dna_exc_c99\t%s\t%s\tdamaged: %d of 3 refused, %d full size; intact: %d of 3 whole\n", control ? "control" : "check", pass ? "pass" : "fail", br, bw, gw);
    free(bad); free(good); return pass ? 0 : 1;
}
