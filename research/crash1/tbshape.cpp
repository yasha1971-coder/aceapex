// tbshape.cpp - aceapex calls exactly as TurboBench plugin.cc (v2026.11.06.164) makes them, under ASan+UBSan:
//   compress: aceapex_compress(in, n, out, cap = 1.3 n + 10 MB, level, threads > 1 ? threads : 1)
//   decompress: aceapex_decompress_mt(in, zs, out, n (exact), threads)
// plus short destinations: compress into zs-1, zs/2, 64 and decompress into n-1, n/2: must return < 0, never write past.
// Usage: tbshape FILE THREADS LEVEL...
#include "aceapex.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
int main(int argc, char** argv) {
    FILE* f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); size_t n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char* in = (unsigned char*)malloc(n); if (fread(in, 1, n, f) != n) return 2; fclose(f);
    setvbuf(stdout, nullptr, _IONBF, 0);
    const int T = atoi(argv[2]); int bad = 0;
    for (int a = 3; a < argc; a++) {
        const int lv = atoi(argv[a]);
        const size_t cap = (size_t)(n * 1.3) + 10 * 1000000ull;
        unsigned char* z = (unsigned char*)malloc(cap);
        const int64_t zs = aceapex_compress(in, n, z, cap, lv, T > 1 ? T : 1);
        unsigned char* o = (unsigned char*)malloc(n);
        const int64_t d = zs > 0 ? aceapex_decompress_mt(z, (size_t)zs, o, n, T > 1 ? T : 1) : -999;
        const bool ok = zs > 0 && d == (int64_t)n && !memcmp(o, in, n);
        printf("%s L%d t%d: bound %zu cap %zu zs %lld dec %lld %s\n", argv[1], lv, T, (size_t)aceapex_compress_bound(n), cap, (long long)zs, (long long)d, ok ? "ok" : "FAIL");
        bad += !ok; free(o);
        if (zs > 0) {
            const size_t sc[3] = {(size_t)zs - 1, (size_t)zs / 2, 64};
            for (size_t c : sc) { unsigned char* s = (unsigned char*)malloc(c); const int64_t r = aceapex_compress(in, n, s, c, lv, T > 1 ? T : 1);
                printf("  compress into %zu: %lld %s\n", c, (long long)r, r < 0 ? "error (ok)" : "SUCCESS INTO SHORT BUFFER"); bad += r >= 0; free(s); }
            const size_t sd[2] = {n - 1, n / 2};
            for (size_t c : sd) { unsigned char* s = (unsigned char*)malloc(c); const int64_t r = aceapex_decompress_mt(z, (size_t)zs, s, c, T > 1 ? T : 1);
                printf("  decompress into %zu: %lld %s\n", c, (long long)r, r < 0 ? "error (ok)" : "SUCCESS INTO SHORT BUFFER"); bad += r >= 0; free(s); }
        }
        free(z);
    }
    free(in);
    printf("tbshape: %d failures\n", bad); return bad ? 1 : 0;
}
