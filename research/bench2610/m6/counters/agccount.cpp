// agccount.cpp - counters per request for M6 (hypotheses H1-H5 of G1), on the COUNTING build of libagc (cnt.h, patch_agc.py);
// never used for timing. agccount <archive.agc> <requests.tsv> <truth.tsv> <out prefix>
// One handle (prefetching = 1), one thread, requests in file order. Per request, between two flags around
// agc_get_ctg_seq: operator new / delete and malloc-family calls of the library (counts, bytes), ZSTD_createDCtx /
// freeDCtx / decompress per call site (calls, compressed bytes in, bytes out), the named events of patch_agc.py.
// Output: <prefix>.req.tsv (one row per request, fixed columns), <prefix>.zstd.tsv (request, site, calls, in, out),
// <prefix>.sum.tsv (means and quantiles). Every answer SHA-256 == truth, else exit 4.
#include "bench_common.h"
#include "agc-api.h"
#include <zstd/lib/zstd.h>
#include <algorithm>
#include <set>
#include <new>
static thread_local bool on = false;
static thread_local std::map<std::string, uint64_t>* EV = nullptr;
struct Z { uint64_t calls = 0, in = 0, out = 0; };
static thread_local std::map<std::string, Z>* ZS = nullptr;
static thread_local uint64_t a_new = 0, a_newb = 0, a_del = 0;                 // plain counters: no allocation inside operator new
static void ev(const char* k, uint64_t v) { if (on && EV) { on = false; (*EV)[k] += v; on = true; } }
static std::string site(const char* f, int l) { const char* s = strrchr(f, '/'); return std::string(s ? s + 1 : f) + ":" + std::to_string(l); }
static void zs(const char* f, int l, uint64_t in, uint64_t out, const char* what) { if (on && ZS) { on = false; auto& z = (*ZS)[std::string(what) + "@" + site(f, l)]; z.calls++; z.in += in; z.out += out; on = true; } }
void agccnt_event(const char* name, uint64_t v) { ev(name, v); }
ZSTD_DCtx* agccnt_createDCtx(const char* f, int l) { zs(f, l, 0, 0, "createDCtx"); return ZSTD_createDCtx(); }
size_t agccnt_freeDCtx(ZSTD_DCtx* c, const char* f, int l) { zs(f, l, 0, 0, "freeDCtx"); return ZSTD_freeDCtx(c); }
size_t agccnt_decompressDCtx(ZSTD_DCtx* c, void* d, size_t dc, const void* s, size_t sc, const char* f, int l) { const size_t r = ZSTD_decompressDCtx(c, d, dc, s, sc); zs(f, l, sc, ZSTD_isError(r) ? 0 : r, "decompressDCtx"); return r; }
size_t agccnt_decompress(void* d, size_t dc, const void* s, size_t sc, const char* f, int l) { const size_t r = ZSTD_decompress(d, dc, s, sc); zs(f, l, sc, ZSTD_isError(r) ? 0 : r, "decompress"); return r; }
// allocations (C++ operators; the library's containers)
void* operator new(size_t n) { if (on) { a_new++; a_newb += n; } void* p = malloc(n ? n : 1); if (!p) throw std::bad_alloc(); return p; }
void* operator new[](size_t n) { return operator new(n); }
void operator delete(void* p) noexcept { if (on && p) a_del++; free(p); }
void operator delete[](void* p) noexcept { operator delete(p); }
void operator delete(void* p, size_t) noexcept { operator delete(p); }
void operator delete[](void* p, size_t) noexcept { operator delete(p); }
int main(int argc, char** argv) {
    if (argc < 5) return 1;
    Truth tr = read_truth(argv[3]); std::vector<Req> q = read_reqs(argv[2]); const std::string pre = argv[4];
    agc_t* h = agc_open(argv[1], 1); if (!h) return 2;
    std::vector<std::map<std::string, uint64_t>> E(q.size()); std::vector<std::map<std::string, Z>> ZZ(q.size()); size_t ok = 0;
    for (size_t i = 0; i < q.size(); i++) {
        std::string out(q[i].len + 1, 0); EV = &E[i]; ZS = &ZZ[i];
        a_new = a_newb = a_del = 0;
        on = true; const int k = agc_get_ctg_seq(h, q[i].sample.c_str(), q[i].ctg.c_str(), (int)q[i].start, (int)(q[i].start + q[i].len - 1), &out[0]); on = false;
        E[i]["alloc_new_calls"] = a_new; E[i]["alloc_new_bytes"] = a_newb; E[i]["alloc_delete_calls"] = a_del;
        ok += k >= 0 && sha_upper(out.data(), q[i].len) == tr.req[q[i].id];
    }
    agc_close(h);
    std::set<std::string> keys; for (auto& m : E) for (auto& kv : m) keys.insert(kv.first);
    FILE* f = fopen((pre + ".req.tsv").c_str(), "w"); fprintf(f, "id\tsample\tcontig\tstart\tlength"); for (auto& k : keys) fprintf(f, "\t%s", k.c_str());
    fprintf(f, "\tzstd_calls\tzstd_in\tzstd_out\tdctx_create\n");
    for (size_t i = 0; i < q.size(); i++) { fprintf(f, "%s\t%s\t%s\t%llu\t%llu", q[i].id.c_str(), q[i].sample.c_str(), q[i].ctg.c_str(), (unsigned long long)q[i].start, (unsigned long long)q[i].len);
        for (auto& k : keys) fprintf(f, "\t%llu", (unsigned long long)(E[i].count(k) ? E[i][k] : 0));
        uint64_t zc = 0, zi = 0, zo = 0, cr = 0; for (auto& kv : ZZ[i]) { if (kv.first.rfind("decompress", 0) == 0) { zc += kv.second.calls; zi += kv.second.in; zo += kv.second.out; } if (kv.first.rfind("createDCtx", 0) == 0) cr += kv.second.calls; }
        fprintf(f, "\t%llu\t%llu\t%llu\t%llu\n", (unsigned long long)zc, (unsigned long long)zi, (unsigned long long)zo, (unsigned long long)cr); }
    fclose(f);
    f = fopen((pre + ".zstd.tsv").c_str(), "w"); fprintf(f, "id\tsite\tcalls\tin_bytes\tout_bytes\n");
    for (size_t i = 0; i < q.size(); i++) for (auto& kv : ZZ[i]) fprintf(f, "%s\t%s\t%llu\t%llu\t%llu\n", q[i].id.c_str(), kv.first.c_str(), (unsigned long long)kv.second.calls, (unsigned long long)kv.second.in, (unsigned long long)kv.second.out);
    fclose(f);
    printf("AGCCOUNT\t%s\t%zu requests\tsha256 %zu/%zu\n", argv[2], q.size(), ok, q.size());
    return ok == q.size() ? 0 : 4;
}
