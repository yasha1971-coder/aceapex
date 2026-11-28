/* boffs_contig_c99.c - claim head_boffs_contig_reject, C99 part (2.6.6; c/aceapex_decode.c = python/csrc/aceapex_decode.c,
 * the Python package's decoder): the three archives of this directory (gen.py) are refused by aceapex_decompress,
 * aceapex_decompress_region (whole and block 6 alone) and aceapex_dec_open; the fixture text_200K decodes whole.
 *   default build:               3 x 4 calls refused, fixture whole on 3                 -> pass
 *   -DAX_BOFFS_CONTIG_NO_CHECK:  the control (2.6.5): decompress and whole region return the full size with bytes other
 *                                than the fixture's on all 3 archives (6 calls)
 * Prints: boffs_contig_c99 <check|control> <pass|fail> <detail>. Usage: boffs_contig_c99 <this directory> <fixtures dir> */
#include "aceapex_decode.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static unsigned char* slurp(const char* dir, const char* name, size_t* n) {
    char p[4096]; snprintf(p, sizeof p, "%s/%s.aet", dir, name); FILE* f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long k = ftell(f); fseek(f, 0, SEEK_SET); if (k < 68) { fclose(f); return NULL; }
    unsigned char* b = (unsigned char*)malloc((size_t)k); *n = fread(b, 1, (size_t)k, f); fclose(f); return b; }
/* 0 refused, 1 full size with the wanted bytes, 2 full size with other bytes, 3 another result */
static int call(const unsigned char* a, size_t na, const unsigned char* want, uint64_t off, uint64_t len, int ep) {
    unsigned char* d = (unsigned char*)malloc(len + 64); int64_t r = -1;
    if (ep == 0) r = aceapex_decompress(a, na, d, len);
    else if (ep == 1) r = aceapex_decompress_region(a, na, d, len, off, len);
    else { aceapex_dec_t* h = aceapex_dec_open(a, na); if (h) { r = aceapex_dec_region(h, d, len, off, len); aceapex_dec_close(h); } }
    const int s = r < 0 ? 0 : r != (int64_t)len ? 3 : !memcmp(d, want + off, len) ? 1 : 2; free(d); return s; }
int main(int argc, char** argv) {
#ifdef AX_BOFFS_CONTIG_NO_CHECK
    const int control = 1;
#else
    const int control = 0;
#endif
    size_t nf = 0; unsigned char* fx = argc > 2 ? slurp(argv[2], "text_200K", &nf) : NULL;
    if (!fx) { printf("boffs_contig_c99\t%s\tfail\tfixture missing\n", control ? "control" : "check"); return 1; }
    uint64_t n; uint32_t bs; memcpy(&n, fx + 12, 8); memcpy(&bs, fx + 20, 4);
    unsigned char* want = (unsigned char*)malloc(n); if (aceapex_decompress(fx, nf, want, n) != (int64_t)n) { printf("boffs_contig_c99\tfail\tfixture does not decode\n"); return 1; }
    static const char* bad[3] = {"last_lit0", "mid_lit0", "mid_lit_shift"};
    int refused = 0, silent = 0, fxw = 0, miss = 0; char det[512] = "";
    for (int ep = 0; ep < 3; ep++) if (call(fx, nf, want, 0, n, ep) == 1) fxw++;
    for (int i = 0; i < 3; i++) { size_t na = 0; unsigned char* a = slurp(argv[1], bad[i], &na); if (!a) { miss++; continue; }
        int r = 0, s2 = 0;
        for (int ep = 0; ep < 3; ep++) { const int s = call(a, na, want, 0, n, ep); if (s == 0) r++; if (s == 2 && ep < 2) s2++; }
        if (call(a, na, want, 6ull * bs, bs, 1) == 0) r++;
        refused += r; silent += s2; snprintf(det + strlen(det), sizeof det - strlen(det), "%s%s %d/4 refused, %d silent", i ? ", " : "", bad[i], r, s2); free(a); }
    const int pass = miss == 0 && fxw == 3 && (control ? silent == 6 : refused == 12);
    printf("boffs_contig_c99\t%s\t%s\t%s; fixture whole on %d of 3%s\n", control ? "control" : "check", pass ? "pass" : "fail", det, fxw, miss ? "; inputs missing" : "");
    free(fx); free(want); return pass ? 0 : 1;
}
