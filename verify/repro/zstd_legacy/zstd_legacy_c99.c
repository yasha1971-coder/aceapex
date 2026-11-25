/* zstd_legacy_c99.c - claim head_zstd_legacy_reject, C99 part (2.6.5, SEC-ZSTD-1): the C99 decoder (c/aceapex_decode.c,
 * the same code as the Python package's csrc/) hands no zstd frame other than a v1 frame to libzstd. Inputs: the four
 * archives of this directory (gen.py), each through aceapex_decompress, aceapex_decompress_region (whole output),
 * aceapex_decompress_ranges (one range) and aceapex_dec_open + aceapex_dec_region. Expectations as in
 * zstd_legacy_test.cpp: default build - zl_v1 decodes to its .expect, the other three fail everywhere;
 * -DAX_ZFRAME_NO_CHECK (negative control) - zl_skip_v1 decodes, and zl_v07 / zl_v1_v07 decode too when the linked
 * libzstd decodes the v0.7 frame alone. Prints one line: zstd_legacy_c99 <check|control> <pass|fail> <detail>.
 * Usage: zstd_legacy_c99 <dir of this directory>
 */
#include "aceapex_decode.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zstd.h>

static unsigned char* slurp(const char* dir, const char* name, const char* ext, size_t* n) {
    char p[4096]; FILE* f; unsigned char* b; long k;
    snprintf(p, sizeof p, "%s/%s%s", dir, name, ext); f = fopen(p, "rb"); if (!f) { *n = 0; return NULL; }
    fseek(f, 0, SEEK_END); k = ftell(f); fseek(f, 0, SEEK_SET); b = (unsigned char*)malloc((size_t)k + 1);
    *n = fread(b, 1, (size_t)k, f); fclose(f); return b;
}

/* 1 = decoded to exactly want, 0 = refused, 2 = success with wrong bytes */
static int call(int ep, const unsigned char* a, size_t an, const unsigned char* want, size_t wn) {
    unsigned char* d = (unsigned char*)calloc(wn + 64, 1); int64_t r = -1; int res;
    if (ep == 0) r = aceapex_decompress(a, an, d, wn);
    else if (ep == 1) r = aceapex_decompress_region(a, an, d, wn, 0, wn);
    else if (ep == 2) { aceapex_range_t g; int64_t t; g.offset = 0; g.length = wn; g.dst = d; g.written = 0;
        t = aceapex_decompress_ranges(a, an, &g, 1, 1); r = t < 0 ? t : g.written; }
    else { aceapex_dec_t* h = aceapex_dec_open(a, an); if (h) { r = aceapex_dec_region(h, d, wn, 0, wn); aceapex_dec_close(h); } }
    res = r < 0 ? 0 : ((size_t)r == wn && !memcmp(d, want, wn) ? 1 : 2);
    free(d); return res;
}

int main(int argc, char** argv) {
    const char* names[4] = {"zl_v1", "zl_v07", "zl_v1_v07", "zl_skip_v1"};
    const char* eps[4] = {"decompress", "region", "ranges", "dec"};
    int legacy = 0, bad = 0, n = 0, i, ep; char det[2048] = "";
#ifdef AX_ZFRAME_NO_CHECK
    const char* mode = "control";
    { size_t an; unsigned char* a = slurp(argv[1], "zl_v07", ".aet", &an); unsigned char probe[1024];
      size_t pr = a && an >= 68 + 64 + 24 + 178 ? ZSTD_decompress(probe, sizeof probe, a + 68 + 64 + 24, 178) : (size_t)-1;
      legacy = !ZSTD_isError(pr) && pr == 239; free(a); }
#else
    const char* mode = "check";
#endif
    if (argc < 2) { fprintf(stderr, "usage: zstd_legacy_c99 DIR\n"); return 2; }
    for (i = 0; i < 4; i++) {
        size_t an, wn; unsigned char* a = slurp(argv[1], names[i], ".aet", &an); unsigned char* w = slurp(argv[1], names[i], ".expect", &wn);
        int is_v1 = !strcmp(names[i], "zl_v1"), is_skip = !strcmp(names[i], "zl_skip_v1"), expect, ok = 0; char t[128];
#ifdef AX_ZFRAME_NO_CHECK
        expect = (is_v1 || is_skip || legacy) ? 1 : -1;
#else
        expect = is_v1 ? 1 : 0; (void)is_skip; (void)legacy;
#endif
        if (!a || !w) { printf("zstd_legacy_c99\t%s\tfail\tmissing %s\n", mode, names[i]); return 1; }
        for (ep = 0; ep < 4; ep++) {
            int r = call(ep, a, an, w, wn);
            if (expect >= 0) { n++; if (r == expect) ok++; else { bad++; snprintf(t, sizeof t, " %s/%s=%d", names[i], eps[ep], r); strncat(det, t, sizeof det - strlen(det) - 1); } }
        }
        if (expect < 0) snprintf(t, sizeof t, " %s:n/a", names[i]); else snprintf(t, sizeof t, " %s:%d/4", names[i], ok);
        strncat(det, t, sizeof det - strlen(det) - 1); free(a); free(w);
    }
    printf("zstd_legacy_c99\t%s\t%s\t%d/%d calls as expected%s%s\n", mode, bad ? "fail" : "pass", n - bad, n, det,
           strcmp(mode, "control") ? "" : (legacy ? " (libzstd decodes legacy frames)" : " (libzstd without legacy: v0.7 cases not judged)"));
    return bad ? 1 : 0;
}
