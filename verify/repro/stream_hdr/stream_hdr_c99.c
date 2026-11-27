/* stream_hdr_c99.c - claim head_stream_hdr_reject, C99 part (2.6.6; c/aceapex_decode.c = python/csrc/aceapex_decode.c, the
 * Python package's decoder): the four archives of this directory (gen.py, README.md) break one stream-header rule each and
 * are refused by aceapex_decompress, aceapex_decompress_region and aceapex_dec_open + aceapex_dec_region; their fixtures
 * (verify/fixtures/conf) decode whole.
 *   default build:             4 x 3 calls refused, fixtures whole on 2 x 3        -> pass
 *   -DAX_STREAM_HDR_NO_CHECK:  the control (the decoder of 2.6.5) - every one of the 4 x 3 calls returns the full size
 * Prints: stream_hdr_c99 <check|control> <pass|fail> <detail>. Usage: stream_hdr_c99 <this directory> <fixtures dir> */
#include "aceapex_decode.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static unsigned char* slurp(const char* dir, const char* name, size_t* n) {
    char p[4096]; snprintf(p, sizeof p, "%s/%s.aet", dir, name); FILE* f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long k = ftell(f); fseek(f, 0, SEEK_SET); if (k < 20) { fclose(f); return NULL; }
    unsigned char* b = (unsigned char*)malloc((size_t)k); *n = fread(b, 1, (size_t)k, f); fclose(f); return b; }
static int full(const unsigned char* a, size_t na, uint64_t n, int ep) {   /* 0 refused, 1 full size, 2 other */
    unsigned char* d = (unsigned char*)malloc(n + 64); int64_t r = -1;
    if (ep == 0) r = aceapex_decompress(a, na, d, n);
    else if (ep == 1) r = aceapex_decompress_region(a, na, d, n, 0, n);
    else { aceapex_dec_t* h = aceapex_dec_open(a, na); if (h) { r = aceapex_dec_region(h, d, n, 0, n); aceapex_dec_close(h); } }
    free(d); return r < 0 ? 0 : r == (int64_t)n ? 1 : 2; }
int main(int argc, char** argv) {
#ifdef AX_STREAM_HDR_NO_CHECK
    const int control = 1;
#else
    const int control = 0;
#endif
    static const char* bad[4] = {"tok_bit63", "litch_e63", "lit4_e63", "lit_tag_nochunk"};
    static const char* fx[2] = {"dna_4096B", "text_legacy4"};
    int br = 0, bw = 0, gw = 0, miss = 0; char det[512] = "";
    for (int i = 0; i < 4 && argc > 2; i++) { size_t na = 0; unsigned char* a = slurp(argv[1], bad[i], &na); if (!a) { miss++; continue; }
        uint64_t n; memcpy(&n, a + 12, 8); int r = 0, w = 0;
        for (int ep = 0; ep < 3; ep++) { const int s = full(a, na, n, ep); if (s == 0) r++; if (s == 1) w++; }
        br += r; bw += w; snprintf(det + strlen(det), sizeof det - strlen(det), "%s%s %d/%d refused", i ? ", " : "", bad[i], r, 3); free(a); }
    for (int i = 0; i < 2 && argc > 2; i++) { size_t na = 0; unsigned char* a = slurp(argv[2], fx[i], &na); if (!a) { miss++; continue; }
        uint64_t n; memcpy(&n, a + 12, 8); for (int ep = 0; ep < 3; ep++) if (full(a, na, n, ep) == 1) gw++; free(a); }
    const int pass = argc > 2 && miss == 0 && gw == 6 && (control ? bw == 12 : br == 12);
    printf("stream_hdr_c99\t%s\t%s\t%s; %d of 12 full size; fixtures whole on %d of 6%s\n", control ? "control" : "check",
           pass ? "pass" : "fail", det, bw, gw, miss ? "; inputs missing" : "");
    return pass ? 0 : 1;
}
