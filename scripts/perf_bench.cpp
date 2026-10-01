// perf_bench.cpp - decode timing for the performance gate (scripts/perf_gate.sh): the archive and the original in
// memory, aceapex_decompress_mt with the given thread budget (0 = all hardware threads), N timed runs after one warm-up,
// every run compared byte for byte with the original. Prints: median_s min_s output_bytes (or MISMATCH, exit 1).
// Build: g++ -std=c++17 -O3 -march=native -Isrc scripts/perf_bench.cpp src/aceapex_api.cpp -lzstd -lpthread
#include "aceapex.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
static std::vector<uint8_t> slurp(const char* p) {
    std::vector<uint8_t> v; FILE* f = fopen(p, "rb"); if (!f) { perror(p); exit(2); }
    fseek(f, 0, SEEK_END); v.resize(ftell(f)); fseek(f, 0, SEEK_SET);
    if (fread(v.data(), 1, v.size(), f) != v.size()) exit(2);
    fclose(f); return v;
}
int main(int argc, char** argv) {
    if (argc < 5) { fprintf(stderr, "usage: %s <archive> <original> <threads> <runs>\n", argv[0]); return 2; }
    const auto a = slurp(argv[1]), o = slurp(argv[2]); const int T = atoi(argv[3]), R = atoi(argv[4]);
    std::vector<uint8_t> d(o.size() + 64); memset(d.data(), 0, d.size());
    std::vector<double> t;
    for (int r = 0; r <= R; r++) {
        const auto t0 = std::chrono::steady_clock::now();
        const int64_t n = aceapex_decompress_mt(a.data(), a.size(), d.data(), d.size(), T);
        const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        if (n != (int64_t)o.size() || memcmp(d.data(), o.data(), o.size())) { printf("MISMATCH\n"); return 1; }
        if (r) t.push_back(s);                                   // run 0: warm-up
    }
    std::sort(t.begin(), t.end());
    printf("%.4f %.4f %zu\n", t[t.size() / 2], t[0], o.size());
    return 0;
}
