// enc_mem_test.cpp - claim head_enc_mem (2.6.4 step 3, MEM): the encoder of the default profile holds the blocks at their
// real size. 32 MiB of seeded word text and 32 MiB of A/C/G/T lines, levels 1-4, 1 and 4 threads: the peak of the bytes
// the library has allocated (live heap above what the test itself holds: malloc / calloc / realloc / aligned_alloc /
// posix_memalign / memalign / free replaced over glibc's __libc_*, sizes from malloc_usable_size) must stay within
// 3 x input + 32 MiB x threads (the worker buffers, ~28.5 x a 1 MiB block each). Until 2.6.3 every block kept its
// worst-case buffers until the streams were joined: ~28.5 x the input (on 32-bit: level 1 failed above ~110 MiB of input,
// VM-263). Every archive round-trips. Linux / glibc only. Prints one judge line: head_enc_mem <pass|fail> <detail>.
#include "aceapex.h"
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <random>
#include <string>
#include <vector>
#include <malloc.h>
extern "C" { void* __libc_malloc(size_t); void* __libc_calloc(size_t, size_t); void* __libc_realloc(void*, size_t);
             void __libc_free(void*); void* __libc_memalign(size_t, size_t); }
static std::atomic<long long> g_live{0}, g_peak{0};
static inline void add(void* p) { if (!p) return; const long long v = g_live.fetch_add((long long)malloc_usable_size(p)) + (long long)malloc_usable_size(p);
    long long pk = g_peak.load(); while (v > pk && !g_peak.compare_exchange_weak(pk, v)) {} }
static inline void sub(void* p) { if (p) g_live.fetch_sub((long long)malloc_usable_size(p)); }
extern "C" void* malloc(size_t n) { void* p = __libc_malloc(n); add(p); return p; }
extern "C" void* calloc(size_t a, size_t b) { void* p = __libc_calloc(a, b); add(p); return p; }
extern "C" void* realloc(void* q, size_t n) { if (!q) return malloc(n); const long long o = (long long)malloc_usable_size(q); void* p = __libc_realloc(q, n);
    if (p) { g_live.fetch_sub(o); add(p); } else if (!n) g_live.fetch_sub(o); return p; }
extern "C" void free(void* p) { sub(p); __libc_free(p); }
extern "C" void* memalign(size_t al, size_t n) { void* p = __libc_memalign(al, n); add(p); return p; }
extern "C" void* aligned_alloc(size_t al, size_t n) { return memalign(al, n); }
extern "C" int posix_memalign(void** r, size_t al, size_t n) { void* p = memalign(al, n); if (!p) return ENOMEM; *r = p; return 0; }

int main() {
    const size_t N = (size_t)32 << 20; std::mt19937 rng(20261122);
    static const char* wd[] = {"the", "of", "and", "genome", "block", "archive", "stream", "decoder", "worker", "buffer"};
    std::string det; bool ok = true;
    for (int kind = 0; kind < 2; kind++) {
        std::vector<uint8_t> in(N); size_t i = 0;
        if (kind == 0) while (i < N) { const char* w = wd[rng() % 10]; while (*w && i < N) in[i++] = (uint8_t)*w++; if (i < N) in[i++] = (rng() % 11) ? ' ' : '\n'; }
        else for (; i < N; i++) in[i] = (i % 61 == 60) ? '\n' : (uint8_t)"ACGT"[rng() & 3];
        std::vector<uint8_t> z(aceapex_compress_bound(N)), out(N);
        for (int T : {1, 4}) for (int L = 1; L <= 4; L++) {
            const long long base = g_live.load(); g_peak.store(base);
            const int64_t k = aceapex_compress(in.data(), N, z.data(), z.size(), L, T);
            const long long peak = g_peak.load() - base;
            const bool rt = k > 0 && aceapex_decompress(z.data(), (size_t)k, out.data(), N) == (int64_t)N && out == in;
            const long long lim = 3 * (long long)N + (long long)T * (32ll << 20);
            const bool good = rt && peak <= lim; ok = ok && good;
            char b[160]; snprintf(b, sizeof b, "%s%s L%d T%d %.0f MiB%s", det.empty() ? "" : ", ", kind ? "DNA" : "text", L, T, peak / 1048576.0, good ? "" : (rt ? " (over)" : " (round trip FAILED)"));
            det += b;
        }
    }
    printf("head_enc_mem\t%s\t32 MiB inputs, peak of the encoder's live heap (limit 3 x input + 32 MiB x threads): %s\n", ok ? "pass" : "fail", det.c_str());
    return ok ? 0 : 1;
}
