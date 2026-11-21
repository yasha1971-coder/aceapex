/* fuzz_c99.c - libFuzzer harness over the C99 decoder (c/aceapex_decode.c = python/csrc, 2.6.4): every entry point.
 * The input is an archive (libFuzzer hands it in a heap buffer of exactly its size: ASan sees a read past it).
 *   aceapex_decoded_size; aceapex_decompress into a buffer of exactly the claimed size (claims above 16 MiB: skipped,
 *   that size is the caller's choice); aceapex_decompress_region (4 KiB at an offset taken from the input);
 *   aceapex_decompress_ranges (3 ranges); aceapex_dec_open + aceapex_dec_region + aceapex_dec_ranges.
 * Only the sanitizers judge: no checksum in this API, a success with other bytes is allowed. An allocation above the
 * limit (ClusterFuzzLite: malloc_limit_mb in fuzz_c99.options; local: ASAN_OPTIONS max_allocation_size_mb) is a crash.
 */
#include "aceapex_decode.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define CLAIM_MAX ((uint64_t)16 << 20)
static uint64_t mix(const uint8_t* d, size_t n) { uint64_t h = 1469598103934665603ull; for (size_t i = 0; i < n && i < 64; i++) h = (h ^ d[i]) * 1099511628211ull; return h; }

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    const int64_t s = aceapex_decoded_size(data, size);
    uint8_t* buf = (uint8_t*)malloc(4096 * 3 + 64);
    if (!buf) return 0;
    if (s >= 0 && (uint64_t)s <= CLAIM_MAX) {
        uint8_t* dst = (uint8_t*)malloc((size_t)s ? (size_t)s : 1);
        if (dst) { (void)aceapex_decompress(data, size, dst, (size_t)s); free(dst); }
    }
    const uint64_t h = mix(data, size), orig = s > 0 ? (uint64_t)s : 4096;
    const uint64_t off = h % orig, len = orig - off < 4096 ? orig - off : 4096;
    (void)aceapex_decompress_region(data, size, buf, 4096, off, len ? len : 1);
    aceapex_range_t rg[3] = {{off, len, buf, 0}, {(h >> 20) % orig, 1, buf + 4096, 0}, {0, orig < 4096 ? orig : 4096, buf + 8192, 0}};
    (void)aceapex_decompress_ranges(data, size, rg, 3, 1);
    aceapex_dec_t* d = aceapex_dec_open(data, size);
    if (d) {
        (void)aceapex_dec_region(d, buf, 4096, off, len ? len : 1);
        aceapex_range_t r2[3] = {rg[0], rg[1], rg[2]};
        (void)aceapex_dec_ranges(d, r2, 3);
        aceapex_dec_close(d);
    }
    free(buf);
    return 0;
}
