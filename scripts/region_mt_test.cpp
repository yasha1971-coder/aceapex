// region_mt_test.cpp - HYBRID-2: aceapex_decompress_region_mt against the original and against aceapex_decompress_region.
//   check  <archive> <original> [threads]  : the whole file, every block-aligned tail split at 10 points, 1 000 random ranges
//                                            (seed 20261127: lengths 1 B .. 3 blocks, offsets anywhere) == the original and ==
//                                            region; a range past the end and dst too small are refused like region
//   speed  <archive> <original> <threads> <first block> [R]: decompress_mt of the whole file (A/A: two blocks of R),
//                                            region_mt of the whole file and of the blocks [first, end) - GB/s of output
// Build: g++ -std=c++17 -O3 -march=native -Isrc -c src/aceapex_api.cpp -o api_lib.o (no -DACEAPEX_CLI: no main);
//        g++ -std=c++17 -O3 -march=native -Isrc scripts/region_mt_test.cpp api_lib.o -lzstd -lpthread
#include "aceapex.h"
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>
static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static std::vector<uint8_t> slurp(const char* p) {
    std::vector<uint8_t> v; FILE* f = fopen(p, "rb"); if (!f) { perror(p); exit(1); }
    fseek(f, 0, SEEK_END); v.resize((size_t)ftell(f)); fseek(f, 0, SEEK_SET);
    if (!v.empty() && fread(v.data(), 1, v.size(), f) != v.size()) { perror(p); exit(1); } fclose(f); return v; }
static double med(std::vector<double> v) { std::sort(v.begin(), v.end()); return v[v.size() / 2]; }
static uint64_t block_size(const std::vector<uint8_t>& a) {   // ACEPX2 header: magic[8], version u32, orig_size u64, block_size u32
    uint32_t v; memcpy(&v, a.data() + 20, 4); return v; }

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc < 4) { fprintf(stderr, "usage: %s check|speed <archive> <original> [threads] [first block] [R]\n", argv[0]); return 1; }
    const std::vector<uint8_t> a = slurp(argv[2]), o = slurp(argv[3]); const uint64_t N = o.size();
    const int thr = argc > 4 ? atoi(argv[4]) : 0; const bool v3 = a.size() >= 12 && a[8] == 3;
    const uint64_t bs = v3 ? 0 : block_size(a); long bad = 0;
    std::vector<uint8_t> out(N + 64), ref(N + 64);
    if (!strcmp(argv[1], "check")) {
        auto one = [&](uint64_t off, uint64_t len, const char* what) {
            const int64_t r = aceapex_decompress_region_mt(a.data(), a.size(), out.data(), len, off, len, thr);
            const int64_t q = aceapex_decompress_region(a.data(), a.size(), ref.data(), len, off, len);
            if (r != (int64_t)len || q != (int64_t)len || memcmp(out.data(), o.data() + off, len) || memcmp(ref.data(), out.data(), len)) {
                if (bad < 10) printf("[rmt] %s off %llu len %llu: region_mt %lld region %lld DIFFERS\n", what, (unsigned long long)off, (unsigned long long)len, (long long)r, (long long)q);
                bad++; } };
        one(0, N, "whole");
        if (bs) for (int k = 1; k <= 10; k++) { const uint64_t nb = (N + bs - 1) / bs, b = nb * k / 11, off = b * bs; if (off < N) one(off, N - off, "tail"); }
        std::mt19937_64 g(20261127ull); const uint64_t mx = bs ? 3 * bs : ((uint64_t)3 << 20);
        for (int i = 0; i < 1000; i++) { const uint64_t len = 1 + g() % std::min<uint64_t>(mx, N), off = g() % (N - len + 1); one(off, len, "random"); }
        const int64_t e1 = aceapex_decompress_region_mt(a.data(), a.size(), out.data(), N, N - 10, 20, thr);
        const int64_t e2 = aceapex_decompress_region_mt(a.data(), a.size(), out.data(), 10, 0, 20, thr);
        const int64_t f1 = aceapex_decompress_region(a.data(), a.size(), out.data(), N, N - 10, 20), f2 = aceapex_decompress_region(a.data(), a.size(), out.data(), 10, 0, 20);
        if (e1 != f1 || e2 != f2) { printf("[rmt] refusals differ: past end %lld/%lld, small dst %lld/%lld\n", (long long)e1, (long long)f1, (long long)e2, (long long)f2); bad++; }
        printf("[rmt] check %s: %s (block %llu, %s, 1 whole + 10 tails + 1000 random + 2 refusals, threads %d)\n", argv[2], bad ? "FAIL" : "ok",
               (unsigned long long)bs, v3 ? "fast profile" : "ACEPX2 v2", thr);
        return bad ? 5 : 0;
    }
    // speed
    const uint64_t first = argc > 5 ? strtoull(argv[5], 0, 10) : 0; const int R = argc > 6 ? atoi(argv[6]) : 7;
    const uint64_t w0 = first * bs, wn = N - w0;
    auto mt = [&] { return aceapex_decompress_mt(a.data(), a.size(), out.data(), N, thr) == (int64_t)N; };
    auto all = [&] { return aceapex_decompress_region_mt(a.data(), a.size(), out.data(), N, 0, N, thr) == (int64_t)N; };
    auto win = [&] { return aceapex_decompress_region_mt(a.data(), a.size(), out.data(), wn, w0, wn, thr) == (int64_t)wn; };
    auto run = [&](auto fn, std::vector<double>& t) { if (!fn()) { printf("[rmt] call failed\n"); exit(4); } for (int r = 0; r < R; r++) { const double s = now_s(); if (!fn()) exit(4); t.push_back(now_s() - s); } };
    std::vector<double> ta, tb, tw, tc;
    run(mt, ta); run(all, tb); run(win, tw); run(mt, tc);
    const bool okw = memcmp(out.data(), o.data(), N) == 0;   // the last call (mt) left the whole file
    if (!win() || memcmp(out.data(), o.data() + w0, wn)) { printf("[rmt] window output DIFFERS\n"); return 5; }
    const double ga = N / med(ta) / 1e9, gc = N / med(tc) / 1e9, gm = std::max(ga, gc), gb = N / med(tb) / 1e9, gw = wn / med(tw) / 1e9;
    printf("[rmt] speed %s threads %d: decompress_mt %.2f / %.2f GB/s (A/A %+.1f %%), region_mt whole %.2f GB/s (x%.3f), region_mt blocks [%llu, end) = %.1f %% of the file %.2f GB/s per byte (x%.3f of mt) | outputs %s\n",
           argv[2], thr, ga, gc, 100 * (gc - ga) / ga, gb, gb / gm, (unsigned long long)first, 100.0 * wn / N, gw, gw / gm, okw ? "== original" : "DIFFERS");
    printf("RMTROW\t%s\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.4f\t%.3f\t%.3f\t%s\n", argv[2], thr, ga, gc, gb, gw, (double)wn / N, gb / gm, gw / gm, okw ? "ok" : "DIFFERS");
    return okw ? 0 : 5;
}
