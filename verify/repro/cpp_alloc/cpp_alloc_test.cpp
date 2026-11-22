// cpp_alloc_test.cpp - claim head_cpp_alloc (2.6.4 step 2): the C++ decoder (library and CLI) does not size an
// allocation from an archive field beyond what the archive or its output can justify, does not read past the archive
// or a decoded window, and does not crash on a damaged archive or .fai. Inputs (gen.py, 132-716 B):
//   ../c99_alloc/*.aet   AUDIT_ALLOC_262 #1, #3, #4, #5 and the slice wrap, through the C++ entry points (#2: region,
//                        ranges and the CLI summed the stream sizes; #8: the CLI allocated the declared literal size)
//   v2_tokwin     #6  a command stream declaring 8.6 GB in tiny chunks: v2.6.3 region / ranges allocate the window
//   v2_bigblock   #7  one block of 1 GiB: v2.6.3 region / ranges allocate the span, CLI d and faidx the output (#9)
//   v2_litlegacy      a legacy literal table pointing past the archive: v2.6.3 copies 4 KiB from past its end
//   v2_lit4zero       the 4-part literal layout of 0 bytes: v2.6.3 region divides by zero (SIGFPE); otherwise
//                     well-formed, so a call may succeed on it (signals and allocations judged)
//   v2_litslice       a block's literal slice past the decoded stream: v2.6.3 region reads past its window
//   threads 1024      #13 a valid one-block fast archive (../../fixtures/conf/rand_fast_7B.aet) streamed with
//                     threads = 1024: v2.6.3 zero-fills 1024 blocks (1 GiB)
//   fai lb 0          #10 a .fai row with bases and line bases 0: v2.6.3 faidx divides by zero
// Every call runs in a child process (a signal or an abort is a failure, not the end of the test): aceapex_decompress_mt
// (1 thread, dst = the claim capped at 64 MiB), _region, _ranges, _stream (VERIFY), aceapex_decode_streams, CLI d and
// CLI faidx (index build and a region). Default build: malloc / calloc / realloc / aligned_alloc / posix_memalign /
// memalign are replaced over glibc's __libc_* (operator new, libzstd and the CLI's posix_memalign included); every
// request is recorded and one above 64 MiB refused. -DCA_SAN (ASan + UBSan, which own malloc): no replacement, the
// sanitizers judge reads; run with ASAN_OPTIONS=allocator_may_return_null=1:max_allocation_size_mb=64.
// Pass: every call on a damaged input fails with a negative code / non-zero exit, no signal, no request above 64 MiB;
// the valid fast archive decodes. Prints one judge line: head_cpp_alloc <pass|fail> <detail> (with -DCA_SAN:
// head_cpp_alloc_san). Usage: cpp_alloc_test <dir of verify/repro> <fixtures dir> <tmp dir>
#define ACEAPEX_CLI
#define main aceapex_cli_main
#include "aceapex_api.cpp"
#undef main
#include <sys/wait.h>
#include <unistd.h>
#include <malloc.h>
#include <string>
#include <vector>

static const size_t LIMIT = (size_t)64 << 20;
static size_t g_max = 0;
#ifndef CA_SAN
extern "C" { void* __libc_malloc(size_t); void* __libc_calloc(size_t, size_t); void* __libc_realloc(void*, size_t); void* __libc_memalign(size_t, size_t); }
static inline bool over(size_t n) { if (n > g_max) g_max = n; return n > LIMIT; }
extern "C" void* malloc(size_t n) { if (over(n)) { errno = ENOMEM; return nullptr; } return __libc_malloc(n); }
extern "C" void* calloc(size_t a, size_t b) { const size_t n = (b && a > SIZE_MAX / b) ? SIZE_MAX : a * b; if (over(n)) { errno = ENOMEM; return nullptr; } return __libc_calloc(a, b); }
extern "C" void* realloc(void* p, size_t n) { if (over(n)) { errno = ENOMEM; return nullptr; } return __libc_realloc(p, n); }
extern "C" void* memalign(size_t al, size_t n) { if (over(n)) { errno = ENOMEM; return nullptr; } return __libc_memalign(al, n); }
extern "C" void* aligned_alloc(size_t al, size_t n) { return memalign(al, n); }
extern "C" int posix_memalign(void** p, size_t al, size_t n) { void* q = memalign(al, n); if (!q) return ENOMEM; *p = q; return 0; }
#endif

struct Res { int64_t rc; size_t maxreq; int sig; };
template <class F> static Res child(F fn) {
    int fd[2]; if (pipe(fd)) return {-999, 0, 0};
    fflush(stdout); fflush(stderr);
    const pid_t pid = fork();
    if (pid == 0) { close(fd[0]); if (!freopen("/dev/null", "w", stderr)) {} if (!freopen("/dev/null", "w", stdout)) {}
        g_max = 0; Res r{fn(), 0, 0}; r.maxreq = g_max; if (write(fd[1], &r, sizeof r) != (ssize_t)sizeof r) {} _exit(0); }
    close(fd[1]); Res r{-998, 0, 0}; const bool got = read(fd[0], &r, sizeof r) == (ssize_t)sizeof r; close(fd[0]);
    int st = 0; waitpid(pid, &st, 0);
    if (WIFSIGNALED(st)) { r.sig = WTERMSIG(st); r.rc = -997; } else if (!got) { r.rc = -996; r.sig = -1; }   // died without a result (a sanitizer report exits 1): signal -1
    return r;
}
static std::vector<uint8_t> slurp(const std::string& p) {
    std::vector<uint8_t> b; FILE* f = fopen(p.c_str(), "rb"); if (!f) return b;
    int c; while ((c = fgetc(f)) != EOF) b.push_back((uint8_t)c); fclose(f); return b;
}
static void put(const std::string& p, const void* d, size_t n) { FILE* f = fopen(p.c_str(), "wb"); if (f) { if (n) fwrite(d, 1, n, f); fclose(f); } }
static int cli(std::vector<std::string> a) {
    std::vector<char*> v; for (auto& s : a) v.push_back(&s[0]); v.push_back(nullptr);
    return aceapex_cli_main((int)a.size(), v.data());
}
struct Mem { const uint8_t* p; size_t n; };
static int64_t mem_rd(void* c, uint64_t off, void* dst, size_t n) { Mem* m = (Mem*)c; if (off >= m->n) return 0; const size_t k = std::min<uint64_t>(n, m->n - off); memcpy(dst, m->p + off, k); return (int64_t)k; }
static int null_wr(void*, const void*, size_t) { return 0; }

int main(int argc, char** argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s <verify/repro dir> <fixtures dir> <tmp dir>\n", argv[0]); return 2; }
    const std::string rep = argv[1], fix = argv[2], tmp = argv[3];
    std::string detail; int bad = 0;
    auto note = [&](const std::string& name, const char* call, const Res& r, bool ok) {
        if (ok && r.maxreq <= LIMIT && !r.sig) return;
        bad++; char b[256]; snprintf(b, sizeof b, "%s%s %s: rc %lld, signal %d, largest request %zu B", detail.empty() ? "" : "; ",
                                     name.c_str(), call, (long long)r.rc, r.sig, r.maxreq);
        if (detail.size() < 1500) detail += b; };
    static const char* names[] = {"c99_alloc/v2_wrap", "c99_alloc/v2_dna", "c99_alloc/v2_lit", "c99_alloc/v2_lit1", "c99_alloc/v2_bs",
        "c99_alloc/v2_slicewrap", "cpp_alloc/v2_tokwin", "cpp_alloc/v2_bigblock", "cpp_alloc/v2_litlegacy", "cpp_alloc/v2_lit4zero",
        "cpp_alloc/v2_litslice"};
    int n_calls = 0; size_t worst = 0;
    for (const char* nm : names) {
        const std::string path = rep + "/" + nm + ".aet"; const std::vector<uint8_t> v = slurp(path);
        if (v.empty()) { printf("head_cpp_alloc\tfail\tcannot read %s\n", path.c_str()); return 1; }
        // the archive in a heap block of exactly its size (a vector's capacity can be larger: ASan would not see a read past the end)
        struct Exact { uint8_t* p; size_t n; const uint8_t* data() const { return p; } size_t size() const { return n; } } a{(uint8_t*)malloc(v.size()), v.size()};
        memcpy(a.p, v.data(), v.size());
        uint64_t claim = 0; memcpy(&claim, a.data() + 12, 8); const size_t cap = (size_t)std::min<uint64_t>(claim, (uint64_t)16 << 20);   // the test's own buffer far under the limit
        const std::string arc = tmp + "/a.aet"; put(arc, a.data(), a.size()); remove((arc + ".fai").c_str());
        Res r[8];
        r[0] = child([&] { std::vector<uint8_t> d(cap + 64); g_max = 0; return aceapex_decompress_mt(a.data(), a.size(), d.data(), cap, 1); });
        r[1] = child([&] { std::vector<uint8_t> d(4096 + 64); return aceapex_decompress_region(a.data(), a.size(), d.data(), 4096, 0, std::min<uint64_t>(claim ? claim : 1, 4096)); });
        r[2] = child([&] { std::vector<uint8_t> d(4096 + 64); aceapex_range_t g{0, std::min<uint64_t>(claim ? claim : 1, 4096), d.data(), 0};
                           const int64_t k = aceapex_decompress_ranges(a.data(), a.size(), &g, 1, 1); return k < 0 ? k : (g.written < 0 ? g.written : (int64_t)1); });
        r[3] = child([&] { Mem m{a.data(), a.size()}; return aceapex_decompress_stream(mem_rd, &m, null_wr, nullptr, 1, ACEAPEX_STREAM_VERIFY); });
        r[4] = child([&] { aceapex_streams_t s; const int k = aceapex_decode_streams(a.data(), a.size(), &s); if (k == 0) aceapex_streams_free(&s); return (int64_t)(k ? k : 1); });
        r[5] = child([&] { return (int64_t)-cli({"aceapex", "d", "--in", arc, "--out", tmp + "/out.bin", "--threads", "1"}); });
        r[6] = child([&] { return (int64_t)-cli({"aceapex", "faidx", arc}); });
        r[7] = child([&] { return (int64_t)-cli({"aceapex", "faidx", arc, "x:1-10"}); });
        static const char* calls[] = {"decompress_mt", "region", "ranges", "stream", "decode_streams", "CLI d", "CLI faidx index", "CLI faidx region"};
        // lit4zero is well-formed apart from its layout (no literals, one token): it may decode (no checksum outside VERIFY);
        // what v2.6.3 got wrong there is the division by zero, so for it only signals and allocations are judged
        const bool may_decode = strstr(nm, "lit4zero") != nullptr;
        for (int k = 0; k < 8; k++) { note(nm, calls[k], r[k], may_decode || r[k].rc < 0); n_calls++; worst = std::max(worst, r[k].maxreq); }
        free(a.p);
    }
    { // #13: a valid one-block fast archive streamed with threads = 1024 must decode, without zero-filling 1024 blocks
        const std::vector<uint8_t> a = slurp(fix + "/rand_fast_7B.aet");
        Res r = child([&] { Mem m{a.data(), a.size()}; return aceapex_decompress_stream(mem_rd, &m, null_wr, nullptr, 1024, ACEAPEX_STREAM_VERIFY); });
        note("rand_fast_7B", "stream threads 1024", r, r.rc == 7); n_calls++; worst = std::max(worst, r.maxreq);
    }
    { // #10: a .fai row with bases and 0 line bases next to a valid archive: faidx refuses it, no SIGFPE
        const std::vector<uint8_t> a = slurp(fix + "/dna_4096B.aet"); const std::string arc = tmp + "/f.aet";
        put(arc, a.data(), a.size()); const char row[] = "x\t100\t0\t0\t0\n"; put(arc + ".fai", row, sizeof row - 1);
        Res r = child([&] { return (int64_t)-cli({"aceapex", "faidx", arc, "x:1-10"}); });
        note("dna_4096B + .fai lb 0", "CLI faidx region", r, r.rc < 0); n_calls++;
    }
#ifdef CA_SAN
    const char* id = "head_cpp_alloc_san";
#else
    const char* id = "head_cpp_alloc";
#endif
    if (!bad) printf("%s\tpass\t11 damaged archives x 8 entry points (decompress_mt, region, ranges, stream, decode_streams, CLI d, faidx index, faidx region), fast archive streamed with 1024 threads, .fai lb 0: %d calls, 0 signals, largest request %zu B (limit 64 MiB)\n", id, n_calls, worst);
    else printf("%s\tfail\t%d of %d calls: %s\n", id, bad, n_calls, detail.c_str());
    return bad ? 1 : 0;
}
