// dec_budget_test.cpp - claim head_dec_budget (lzbench #357, 2.6.1): aceapex_decompress_mt(threads = budget) never has
// more than `budget` threads alive at once (the caller included). Counted by wrapping pthread_create
// (-Wl,--wrap=pthread_create). Until 2.6.0 the match phase spawned `budget` threads while the caller waited (budget + 1),
// and token streams under half a thread's share got a thread on top of the budget. Input: 48 MiB of seeded word text
// (literal chunks above the 256 KiB tile limit: the non-tiled path) and 8 MiB of A/C/G/T lines (DNA literals);
// budgets 2, 3, 4 and 8, 3 decodes each. Prints one judge line: head_dec_budget <pass|fail> <detail>.
#include "aceapex.h"
#include <cstdio>
#include <cstring>
#include <vector>
#include <atomic>
#include <random>
#include <string>
#include <pthread.h>
static std::atomic<int> live{1}, peak{1};
struct W { void* (*f)(void*); void* a; };
static void* tramp(void* p) { W w = *(W*)p; delete (W*)p; const int k = ++live; int q = peak.load(); while (k > q && !peak.compare_exchange_weak(q, k)) {} void* r = w.f(w.a); --live; return r; }
extern "C" int __real_pthread_create(pthread_t*, const pthread_attr_t*, void* (*)(void*), void*);
extern "C" int __wrap_pthread_create(pthread_t* t, const pthread_attr_t* at, void* (*f)(void*), void* a) { return __real_pthread_create(t, at, tramp, new W{f, a}); }
int main() {
    std::mt19937 rng(20261103); std::vector<std::vector<uint8_t>> ins(2);
    { static const char* wd[] = {"the", "of", "and", "genome", "block", "archive", "decoder", "thread", "budget", "lzbench", "silesia", "random"};
      std::string s; while (s.size() < (48u << 20)) { s += wd[rng() % 12]; s += (rng() % 11) ? ' ' : '\n'; } ins[0].assign(s.begin(), s.begin() + (48u << 20)); }
    { const char B[4] = {'A', 'C', 'G', 'T'}; ins[1].resize(8u << 20); for (size_t i = 0; i < ins[1].size(); i++) ins[1][i] = (i % 61 == 60) ? '\n' : (uint8_t)B[rng() & 3]; }
    const char* nm[2] = {"text 48 MiB", "DNA 8 MiB"}; int over = 0, fail = 0; std::string det;
    for (int k = 0; k < 2; k++) {
        const std::vector<uint8_t>& in = ins[k]; const size_t n = in.size(); std::vector<uint8_t> z(aceapex_compress_bound(n)), o(n);
        const int64_t zs = aceapex_compress(in.data(), n, z.data(), z.size(), 1, 8); if (zs <= 0) { fail++; continue; }
        det += std::string(" ") + nm[k] + ":";
        for (int b : {2, 3, 4, 8}) { int pk = 0;
            for (int r = 0; r < 3; r++) { live = 1; peak = 1; const int64_t d = aceapex_decompress_mt(z.data(), zs, o.data(), n, b);
                if (d != (int64_t)n || memcmp(o.data(), in.data(), n)) fail++;
                if (peak > pk) pk = peak; }
            over += pk > b; det += " " + std::to_string(b) + "->" + std::to_string(pk); }
    }
    const bool ok = !over && !fail;
    printf("head_dec_budget\t%s\tpeak threads alive in aceapex_decompress_mt per budget (budget->peak, 3 decodes):%s; over budget %d, failed decodes %d\n", ok ? "pass" : "fail", det.c_str(), over, fail);
    return ok ? 0 : 1;
}
