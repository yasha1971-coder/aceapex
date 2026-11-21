/* c99_alloc_test.c - claim head_c99_alloc (2.6.4 step 1): the C99 decoder (c/aceapex_decode.c, the same code as the
 * Python package's csrc/) does not size allocations from archive fields beyond what the archive or its output can
 * justify, and does not read past the archive. Inputs: the six archives of this directory (gen.py), 132-248 B each,
 * from the audit of 13.11 (AUDIT_ALLOC_262):
 *   v2_wrap  #1 the u64 sum header + table + stream sizes wraps -> the size check passes (v2.6.3: reads 64 MiB past the end)
 *   v2_dna   #3 a DNA literal chunk claims nexc = 2^32 - 1 exceptions (v2.6.3: malloc 16 GiB + 4 GiB, memset)
 *   v2_lit   #4 a literal stream of 2^36 B in chunks of 2^35, a block slice across both (v2.6.3: realloc 32 GiB)
 *   v2_lit1  #4 one literal chunk of 2^34 B (v2.6.3: realloc 16 GiB)
 *   v2_bs    #5 block_size 2^32 - 1, empty streams (v2.6.3: malloc 4 GiB in region / ranges / dec_open)
 *   v2_slicewrap  found by fuzz_c99 (21.11): a block entry lit_off + lit_sz wraps past 2^64, the slice looks empty and
 *            the block decoder copies literals from the archive itself past its end (v2.6.3: ASan heap-buffer-overflow)
 * Every input through aceapex_decompress (dst capacity = the claimed size, capped at 64 MiB), _region, _ranges and
 * aceapex_dec_open + aceapex_dec_region. malloc / calloc / realloc are wrapped (-Wl,--wrap): every request is recorded
 * and one above 64 MiB is refused (NULL), so v2.6.3 fails here without touching that memory. Pass: every call gives a
 * negative code (or no handle), no request above 64 MiB; built under ASan+UBSan in the judge (a read past the archive,
 * finding #1, is an ASan report). Prints one judge line: head_c99_alloc <pass|fail> <detail>.
 * Usage: c99_alloc_test <dir with the six .aet>
 */
#include "aceapex_decode.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LIMIT ((size_t)64 << 20)
static size_t g_max = 0, g_refused = 0;
void* __real_malloc(size_t); void* __real_calloc(size_t, size_t); void* __real_realloc(void*, size_t);
static int over(size_t n) { if (n > g_max) g_max = n; if (n > LIMIT) { g_refused++; return 1; } return 0; }
void* __wrap_malloc(size_t n) { return over(n) ? NULL : __real_malloc(n); }
void* __wrap_calloc(size_t a, size_t b) { size_t n = (b && a > SIZE_MAX / b) ? SIZE_MAX : a * b; return over(n) ? NULL : __real_calloc(a, b); }
void* __wrap_realloc(void* p, size_t n) { return over(n) ? NULL : __real_realloc(p, n); }

static unsigned char* slurp(const char* path, size_t* n) {
    FILE* f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long k = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char* b = (unsigned char*)__real_malloc((size_t)k ? (size_t)k : 1);   /* exactly the archive: ASan sees a read past it */
    if (b && fread(b, 1, (size_t)k, f) != (size_t)k) { free(b); b = NULL; }
    fclose(f); *n = (size_t)k; return b;
}

int main(int argc, char** argv) {
    const char* dir = argc > 1 ? argv[1] : ".";
    static const char* names[] = {"v2_wrap", "v2_dna", "v2_lit", "v2_lit1", "v2_bs", "v2_slicewrap"};
    char detail[2048] = ""; int bad = 0;
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        char path[1024]; snprintf(path, sizeof path, "%s/%s.aet", dir, names[i]);
        size_t n = 0; unsigned char* a = slurp(path, &n);
        if (!a) { printf("head_c99_alloc\tfail\tcannot read %s\n", path); return 1; }
        g_max = 0; g_refused = 0;
        int64_t claimed = aceapex_decoded_size(a, n);
        size_t cap = claimed > 0 ? ((uint64_t)claimed < LIMIT ? (size_t)claimed : LIMIT) : 0;
        unsigned char* dst = (unsigned char*)__real_malloc(cap + 64);
        int64_t r_full = aceapex_decompress(a, n, dst, cap);
        int64_t r_reg = aceapex_decompress_region(a, n, dst, cap ? cap : 1, 0, 1);
        aceapex_range_t rg = {0, 1, dst, 0};
        int64_t r_rgs = aceapex_decompress_ranges(a, n, &rg, 1, 1);
        aceapex_dec_t* h = aceapex_dec_open(a, n); int64_t r_h = -100;
        if (h) { r_h = aceapex_dec_region(h, dst, cap ? cap : 1, 0, 1); aceapex_dec_close(h); }
        /* a call may succeed only if it did not over-allocate; the archives are corrupt, so a success with output is a fail too */
        int ok = r_full < 0 && r_reg < 0 && (r_rgs < 0 || (r_rgs == 0 && rg.written < 0)) && (!h || r_h < 0) && g_max <= LIMIT;   /* ranges: the call refused, or the range did */
        if (!ok) bad++;
        char line[256];
        snprintf(line, sizeof line, "%s%s %zu B: full %lld, region %lld, ranges %lld/%lld, handle %s %lld, largest request %zu B%s",
                 i ? "; " : "", names[i], n, (long long)r_full, (long long)r_reg, (long long)r_rgs, (long long)rg.written,
                 h ? "yes" : "no", (long long)(h ? r_h : 0), g_max, ok ? "" : " (FAIL)");
        strncat(detail, line, sizeof detail - strlen(detail) - 1);
        free(dst); free(a);
    }
    printf("head_c99_alloc\t%s\t%s\n", bad ? "fail" : "pass", detail);
    return bad ? 1 : 0;
}
