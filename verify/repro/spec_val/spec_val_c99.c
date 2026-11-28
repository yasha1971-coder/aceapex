/* spec_val_c99.c - claim head_spec_val, C99 part (2.6.7, SPEC-VAL-1; c/ = python/csrc): lit_ch32k (D7), lit_ch65636 (D6),
 * zstd_multi (D8), varint_cut (D9), dna_noexc_h3 (D18) refused by aceapex_decompress, aceapex_decompress_region (whole) and
 * aceapex_dec_open + aceapex_dec_region; a region read of 0 bytes of trunc100 refused (D13).
 *   default build: 5 x 3 refused + trunc100                                                                    -> pass
 *   control -DAX_LITCH_NO_CHECK -DAX_ZFRAME_MULTI_NO_CHECK -DAX_VARINT_NO_CHECK -DAX_DNA_NOEXC_NO_CHECK -DAX_REGION0_NO_CHECK
 *          (the decoder of 2.6.6): the 5 decode to the full size with the original bytes, the 0-byte region returns 0
 * Prints: spec_val_c99 <check|control> <pass|fail> <detail>. Usage: spec_val_c99 <this directory> <fixtures/conf> */
#include "aceapex_decode.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static unsigned char* slurp(const char* d, const char* n, size_t* k) { char p[4096]; snprintf(p, sizeof p, "%s/%s.aet", d, n); FILE* f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long z = ftell(f); fseek(f, 0, SEEK_SET); unsigned char* b = (unsigned char*)malloc(z > 0 ? (size_t)z : 1); *k = fread(b, 1, (size_t)z, f); fclose(f); return b; }
int main(int argc, char** argv) {
#if defined(AX_LITCH_NO_CHECK) && defined(AX_ZFRAME_MULTI_NO_CHECK) && defined(AX_VARINT_NO_CHECK) && defined(AX_DNA_NOEXC_NO_CHECK) && defined(AX_REGION0_NO_CHECK)
    const int control = 1;
#else
    const int control = 0;
#endif
    static const char* cs[5][2] = {{"lit_ch32k", "text_767B"}, {"lit_ch65636", "text_767B"}, {"zstd_multi", "text_767B"}, {"varint_cut", "dna_open_4097B"}, {"dna_noexc_h3", "dna_noexc_intact"}};
    int refused = 0, whole = 0, miss = 0; char det[512] = "";
    if (argc < 3) return 2;
    for (int i = 0; i < 5; i++) { size_t na = 0, nf = 0; unsigned char* a = slurp(argv[1], cs[i][0], &na);
        unsigned char* f = slurp(strcmp(cs[i][1], "dna_noexc_intact") ? argv[2] : argv[1], cs[i][1], &nf);
        if (!a || !f) { miss++; free(a); free(f); continue; }
        uint64_t n; memcpy(&n, f + 12, 8); unsigned char* o = (unsigned char*)malloc(n + 64); unsigned char* d = (unsigned char*)malloc(n + 64);
        if (aceapex_decompress(f, nf, o, n) != (int64_t)n) miss++;
        int r = 0; int64_t q = aceapex_decompress(a, na, d, n); if (q < 0) r++; else if (q == (int64_t)n && !memcmp(d, o, n)) whole++;
        if (aceapex_decompress_region(a, na, d, n, 0, n) < 0) r++;
        aceapex_dec_t* h = aceapex_dec_open(a, na); if (!h || aceapex_dec_region(h, d, n, 0, n) < 0) r++; if (h) aceapex_dec_close(h);
        refused += r; snprintf(det + strlen(det), sizeof det - strlen(det), "%s%s %d/3", i ? ", " : "", cs[i][0], r);
        free(a); free(f); free(o); free(d); }
    size_t nt = 0; unsigned char* t = slurp(argv[1], "trunc100", &nt); unsigned char x[8];
    const int64_t z = t ? aceapex_decompress_region(t, nt, x, 8, 0, 0) : 0; if (!t) miss++; free(t);
    const int pass = miss == 0 && (control ? whole == 5 && z == 0 : refused == 15 && z < 0);
    printf("spec_val_c99\t%s\t%s\trefused: %s; decompress whole with the original bytes %d of 5; 0-byte region of trunc100: %lld%s\n", control ? "control" : "check", pass ? "pass" : "fail", det, whole, (long long)z, miss ? "; inputs missing" : "");
    return pass ? 0 : 1;
}
