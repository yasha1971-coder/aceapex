// alloc_fail_test.cpp - claim head_alloc_fail (2.6.3): an allocation that fails inside any public function gives a
// negative code (ACEAPEX_ERR_MEMORY), never an exception, an abort or a leak. malloc / calloc / realloc / aligned_alloc /
// posix_memalign / free are replaced here (glibc's __libc_* underneath); operator new goes through malloc, so a refused
// malloc is also a std::bad_alloc wherever the library uses new or std::vector - on the caller's thread and on the
// threads a call starts (libzstd's allocations are refused the same way). For every entry point, archive kind and thread
// count the call is run once unarmed (N allocations), then with allocation k refused, k = 0 .. N-1 (one refusal), and
// with every allocation from k on refused (memory exhausted, the 32-bit case of 2.6.2: aceapex,1 then aceapex_fast,1 on
// silesia.tar aborted lzbench). Each run must give the right result (a refusal the library works around) or
// ACEAPEX_ERR_MEMORY, and as many allocations live after the call as before it. v2.6.2 aborts (std::terminate) or leaks.
// Prints one judge line: head_alloc_fail <pass|fail> <detail>. Linux / glibc only (the __libc_* allocator).
#include "aceapex.h"
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>
#include <malloc.h>

extern "C" { void* __libc_malloc(size_t); void* __libc_calloc(size_t, size_t); void* __libc_realloc(void*, size_t);
             void __libc_free(void*); void* __libc_memalign(size_t, size_t); }
static std::atomic<bool> g_arm{false}, g_persist{false};
static std::atomic<long> g_cnt{0}, g_fail{-1}, g_live{0}, g_refused{0};
static inline bool refuse() {
    if (!g_arm.load(std::memory_order_relaxed)) return false;
    const long k = g_cnt.fetch_add(1), f = g_fail.load();
    if (f >= 0 && (k == f || (g_persist.load() && k > f))) { g_refused.fetch_add(1); errno = ENOMEM; return true; }   // as malloc (glibc's pthread_create asserts it)
    return false;
}
static inline void* took(void* p) { if (p) g_live.fetch_add(1); return p; }
extern "C" {
void* malloc(size_t n) { return refuse() ? nullptr : took(__libc_malloc(n)); }
void* calloc(size_t a, size_t b) { return refuse() ? nullptr : took(__libc_calloc(a, b)); }
void* realloc(void* p, size_t n) {
    if (!p) return malloc(n);
    if (!n) { g_live.fetch_sub(1); return __libc_realloc(p, 0); }
    return refuse() ? nullptr : __libc_realloc(p, n); }
void free(void* p) { if (p) { g_live.fetch_sub(1); __libc_free(p); } }
void* aligned_alloc(size_t al, size_t n) { return refuse() ? nullptr : took(__libc_memalign(al, n)); }
void* memalign(size_t al, size_t n) { return refuse() ? nullptr : took(__libc_memalign(al, n)); }
int posix_memalign(void** r, size_t al, size_t n) { if (refuse()) return 12; void* p = took(__libc_memalign(al, n)); if (!p) return 12; *r = p; return 0; }
}

typedef std::vector<uint8_t> Buf;
static Buf text(size_t n, uint32_t seed) {                 // words of a small vocabulary: compressible, not DNA
    static const char* W[] = {"the ", "of ", "archive ", "block ", "decoder ", "stream ", "range ", "level ", "thread ",
                              "memory ", "literal ", "match ", "offset ", "length ", "table ", "chunk ", "\n", ", "};
    Buf b; b.reserve(n + 16); uint32_t x = seed;
    while (b.size() < n) { x = x * 1103515245u + 12345u; const char* w = W[(x >> 16) % 18]; b.insert(b.end(), w, w + strlen(w));
                           if ((x >> 8) % 61 == 0) { char d[16]; snprintf(d, sizeof d, "%u ", x % 100000); b.insert(b.end(), d, d + strlen(d)); } }
    b.resize(n); return b;
}
static Buf dna(size_t n, uint32_t seed) {                  // ACGT with repeats, soft-masked runs and N runs
    Buf b(n); uint32_t x = seed; const char* A = "ACGT";
    for (size_t i = 0; i < n; i++) { x = x * 1664525u + 1013904223u;
        if (i > 5000 && (x >> 24) < 40) { const size_t L = 50 + (x >> 4) % 400, s = i - 1000 - (x >> 8) % 3000; for (size_t k = 0; k < L && i < n; k++, i++) b[i] = b[s + k]; i--; continue; }
        b[i] = (uint8_t)A[(x >> 13) & 3]; }
    for (size_t i = 0; i + 300 < n; i += 70001) memset(&b[i], 'N', 200);
    for (size_t i = 3000; i + 500 < n; i += 50003) for (size_t k = 0; k < 500; k++) b[i + k] |= 0x20;
    for (size_t i = 0; i < n; i += 61) b[i] = '\n';
    return b;
}

// one call: 0 = right result, 1 = ACEAPEX_ERR_MEMORY, 2 = anything else (wrong code or wrong bytes)
typedef std::function<int()> Call;
static int64_t g_last = 0;                                // the last call's return value (for the report)
struct Case { std::string name; Call call; };
static long g_runs = 0, g_ok = 0, g_mem = 0, g_refusals = 0; static std::vector<std::string> g_bad;
static void bad(const std::string& s) { if (g_bad.size() < 12) g_bad.push_back(s); }
static int armed(const Call& c, long fail, bool persist, long* n, long* leak) {
    g_cnt = 0; g_fail = fail; g_persist = persist; g_refused = 0;
    const long l0 = g_live.load(); g_arm = true; const int r = c(); g_arm = false;
    *n = g_cnt.load(); *leak = g_live.load() - l0; return r;
}
static void sweep(const Case& c, long max_runs) {
    long n = 0, leak = 0;
    for (int w = 0; w < 2; w++) armed(c.call, -1, false, &n, &leak);          // warm-up: lazy statics, thread caches
    const int r0 = armed(c.call, -1, false, &n, &leak);
    if (r0 != 0) { bad(c.name + ": unarmed result " + std::to_string(r0) + " (" + std::to_string(g_last) + ")"); return; }
    if (leak) { bad(c.name + ": unarmed leak " + std::to_string(leak)); return; }
    const long step = n > max_runs ? (n + max_runs - 1) / max_runs : 1;
    for (int persist = 0; persist < 2; persist++)
        for (long k = 0; k < n; k += step) {
            if (getenv("AF_VERBOSE")) fprintf(stderr, "%s %s %ld/%ld\n", c.name.c_str(), persist ? "from" : "at", k, n);
            long m = 0; const int r = armed(c.call, k, persist, &m, &leak); g_runs++; g_refusals += g_refused.load();
            if (r == 0) g_ok++; else if (r == 1) g_mem++;
            else bad(c.name + (persist ? " from " : " at ") + std::to_string(k) + "/" + std::to_string(n) + ": wrong result (" + std::to_string(g_last) + ")");
            if (leak) bad(c.name + (persist ? " from " : " at ") + std::to_string(k) + "/" + std::to_string(n) + ": " + std::to_string(leak) + " allocations leaked");
        }
}

// the test's own buffers are allocated with the refusals off (Quiet), only the library's allocations are counted
struct Quiet { bool w; Quiet() : w(g_arm.exchange(false)) {} ~Quiet() { g_arm = w; } };
template <class T> static T* quiet_new(size_t n) { Quiet q; return new T(n); }
static int code(int64_t r, int64_t want) { g_last = r; return r == want ? 0 : r == ACEAPEX_ERR_MEMORY ? 1 : 2; }
struct Mem { const Buf* z; };
static int64_t rd(void* c, uint64_t off, void* dst, size_t n) { const Buf& z = *((Mem*)c)->z; if (off >= z.size()) return 0;
    const size_t k = (size_t)std::min<uint64_t>(n, z.size() - off); memcpy(dst, z.data() + off, k); return (int64_t)k; }
struct Out { Buf* o; size_t at; };
static int wr(void* c, const void* p, size_t n) { Out& o = *(Out*)c; if (o.at + n > o.o->size()) return 1; memcpy(o.o->data() + o.at, p, n); o.at += n; return 0; }

int main(int argc, char** argv) {
    const long MAXR = argc > 1 ? atol(argv[1]) : 400;       // refusal points per case and mode (all of them when fewer)
    const Buf T = text(1300000, 7), D = dna(1100000, 11), D2 = dna(300000, 13);   // D2: level 18 (the optimal parse) is slow
    struct Arc { std::string name; const Buf* src; int level; Buf z; };
    std::vector<Arc> arcs = {{"text-l1", &T, 1, {}}, {"text-l2", &T, 2, {}}, {"text-l3", &T, 3, {}}, {"text-l4", &T, 4, {}},
                             {"dna-l2", &D, 2, {}}, {"text-f11", &T, 11, {}}, {"text-f14", &T, 14, {}}, {"dna-f18", &D2, 18, {}}};
    for (Arc& a : arcs) { a.z.resize(aceapex_compress_bound(a.src->size()));
        const int64_t r = aceapex_compress(a.src->data(), a.src->size(), a.z.data(), a.z.size(), a.level, 4);
        if (r <= 0) { printf("head_alloc_fail\tfail\tsetup: compress %s gave %lld\n", a.name.c_str(), (long long)r); return 1; }
        a.z.resize((size_t)r); }
    std::vector<Case> cs;
    for (const Arc& a : arcs) for (int t : {1, 4}) {              // aceapex_compress: the result must decode to the input
        const Arc* ap = &a;
        cs.push_back({"compress " + a.name + " t" + std::to_string(t), [ap, t] {
            Buf* z = quiet_new<Buf>(aceapex_compress_bound(ap->src->size()));
            const int64_t r = aceapex_compress(ap->src->data(), ap->src->size(), z->data(), z->size(), ap->level, t);
            Quiet q; int c = r < 0 ? (r == ACEAPEX_ERR_MEMORY ? 1 : 2) : 2;
            if (r >= 0) { Buf o(ap->src->size() + 64); const int64_t d = aceapex_decompress_mt(z->data(), (size_t)r, o.data(), o.size(), 1);
                          c = d == (int64_t)ap->src->size() && !memcmp(o.data(), ap->src->data(), (size_t)d) ? 0 : 2; }
            delete z; return c; }});
    }
    for (const Arc& a : arcs) {
        const Arc* ap = &a; const int64_t N = (int64_t)a.src->size();
        for (int t : {0, 1, 4}) cs.push_back({"decompress" + std::string(t ? "_mt t" + std::to_string(t) : "") + " " + a.name, [ap, t, N] {
            Buf* o = quiet_new<Buf>((size_t)N + 64);
            const int64_t r = t ? aceapex_decompress_mt(ap->z.data(), ap->z.size(), o->data(), o->size(), t) : aceapex_decompress(ap->z.data(), ap->z.size(), o->data(), o->size());
            Quiet q; const int c = code(r, N), v = c == 0 && memcmp(o->data(), ap->src->data(), (size_t)N) ? 2 : c; delete o; return v; }});
        for (int t : {1, 4}) cs.push_back({"stream t" + std::to_string(t) + " " + a.name, [ap, t, N] {
            Buf* o = quiet_new<Buf>((size_t)N); Mem m{&ap->z}; Out w{o, 0};
            const int64_t r = aceapex_decompress_stream(rd, &m, wr, &w, t, ACEAPEX_STREAM_VERIFY);
            Quiet q; const int c = code(r, N), v = c == 0 && (w.at != (size_t)N || memcmp(o->data(), ap->src->data(), (size_t)N)) ? 2 : c; delete o; return v; }});
        cs.push_back({"region " + a.name, [ap, N] {
            const uint64_t off = (uint64_t)N / 3, len = std::min<uint64_t>(400000, (uint64_t)N / 2); Buf* o = quiet_new<Buf>(len);
            const int64_t r = aceapex_decompress_region(ap->z.data(), ap->z.size(), o->data(), o->size(), off, len);
            Quiet q; const int c = code(r, (int64_t)len), v = c == 0 && memcmp(o->data(), ap->src->data() + off, len) ? 2 : c; delete o; return v; }});
        for (size_t cnt : {(size_t)40, (size_t)600}) cs.push_back({"ranges x" + std::to_string(cnt) + " " + a.name, [ap, N, cnt] {
            std::vector<aceapex_range_t>* rg = quiet_new<std::vector<aceapex_range_t>>(cnt); Buf* o = quiet_new<Buf>(cnt * 3000); uint32_t x = 5;
            for (size_t i = 0; i < cnt; i++) { x = x * 1103515245u + 12345u; (*rg)[i].offset = (x >> 4) % ((uint64_t)N - 3000);
                (*rg)[i].length = 1 + (x >> 20) % 2999; (*rg)[i].dst = o->data() + i * 3000; (*rg)[i].written = 0; }
            const int64_t r = aceapex_decompress_ranges(ap->z.data(), ap->z.size(), rg->data(), cnt, 4);
            Quiet q; int c = r == ACEAPEX_ERR_MEMORY ? 1 : r == (int64_t)cnt ? 0 : 2;
            for (size_t i = 0; c == 0 && i < cnt; i++) if ((*rg)[i].written != (int64_t)(*rg)[i].length || memcmp((*rg)[i].dst, ap->src->data() + (*rg)[i].offset, (*rg)[i].length)) c = 2;
            delete rg; delete o; return c; }});
        if (a.level < 11) cs.push_back({"decode_streams " + a.name, [ap] {
            aceapex_streams_t s; const int r = aceapex_decode_streams(ap->z.data(), ap->z.size(), &s);
            if (r < 0) return r == ACEAPEX_ERR_MEMORY && !s.lit && !s.boffs_vec ? 1 : 2;
            const int c = s.num_blocks && s.lit && s.off && s.len && s.cmd && s.boffs ? 0 : 2; aceapex_streams_free(&s); return c; }});
    }
    const char* only = getenv("AF_ONLY");                    // diagnostics: the cases whose name contains this
    for (const Case& c : cs) if (!only || c.name.find(only) != std::string::npos) sweep(c, MAXR);
    const bool ok = g_bad.empty() && g_runs > 0;
    printf("head_alloc_fail\t%s\t%zu cases (compress 1-4 and 11/14/18, decompress, _mt, stream, region, ranges, decode_streams; 1 and 4 threads), "
           "%ld runs with %ld refused allocations: %ld right result, %ld ACEAPEX_ERR_MEMORY, %zu bad%s%s\n",
           ok ? "pass" : "fail", cs.size(), g_runs, g_refusals, g_ok, g_mem, g_bad.size(), g_bad.empty() ? "" : ": ", g_bad.empty() ? "" : g_bad[0].c_str());
    for (size_t i = 1; i < g_bad.size(); i++) fprintf(stderr, "  %s\n", g_bad[i].c_str());
    return ok ? 0 : 1;
}
