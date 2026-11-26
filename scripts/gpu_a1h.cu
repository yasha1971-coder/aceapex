// gpu_a1h.cu - GPU-A1 hypotheses on the ACEAPEX windows API (measurement branch gpu-a1, never merged).
// Same windows as scripts/gpu_a1.cu (n x W, seed 20261127; single windows: seed 777, 200 calls).
//   base   phase breakdown of one call (CUDA events after each enqueued phase, -DAXW_PROF hook), n windows and 1 window
//   V0     production match kernel; V1 parse only (timing; output wrong by design, never compared);
//   V2     H3 / C-030: output through a 4 KiB shared-memory ring per warp, 16-byte line flushes
//   H1     one window by a CUDA Graph of the whole call (V0 and V2): no host launches per call
// Equivalence (Kill): every window of V0, V2 and the graphs == the original; plus the whole file for V0 and V2
// (one window of block_size per block). Any difference: KILL line, exit 5.
// Build: nvcc -std=c++17 -O3 -arch=sm_90 -DAXW_PROF -Isrc scripts/gpu_a1h.cu src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp -o gpu_a1h
// Run:   gpu_a1h <archive.open.aet> <original> <tag> [n] [W] [R]
#include "aceapex_gpu.h"
#include <cuda_runtime.h>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

extern "C" int axw_variant;
extern "C" void (*axw_hook)(int, cudaStream_t);
extern "C" void axw_info(const aceapex_gpu_plan* p, uint64_t* v);

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { printf("CUDA %s @%d: %s\n", #x, __LINE__, cudaGetErrorString(e_)); exit(2); } } while (0)
static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static std::vector<uint8_t> slurp(const char* p) {
    std::vector<uint8_t> v; FILE* f = fopen(p, "rb"); if (!f) { perror(p); exit(1); }
    fseek(f, 0, SEEK_END); v.resize((size_t)ftell(f)); fseek(f, 0, SEEK_SET);
    if (!v.empty() && fread(v.data(), 1, v.size(), f) != v.size()) { perror(p); exit(1); } fclose(f); return v; }
static double pct(std::vector<double> v, double p) { if (v.empty()) return 0; std::sort(v.begin(), v.end()); return v[std::min(v.size() - 1, (size_t)(p * v.size()))]; }

static cudaEvent_t g_ev[7]; static bool g_evset[7];
static void hook(int k, cudaStream_t s) { if (k >= 0 && k < 7) { cudaEventRecord(g_ev[k], s); g_evset[k] = true; } }

static const char* g_tag = ""; static bool g_kill = false;
static bool same(const uint8_t* got, const std::vector<uint8_t>& o, const uint64_t* off, uint32_t n, uint32_t W, const char* what) {
    for (uint32_t i = 0; i < n; i++) if (memcmp(got + (size_t)i * W, o.data() + off[i], W)) {
        printf("[a1h] %s %s: window %u (offset %llu) differs\n", g_tag, what, i, (unsigned long long)off[i]); return false; }
    return true;
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc < 4) { fprintf(stderr, "usage: %s <archive.open.aet> <original> <tag> [n] [W] [R]\n", argv[0]); return 1; }
    g_tag = argv[3];
    const std::vector<uint8_t> a = slurp(argv[1]), o = slurp(argv[2]); const uint64_t orig = o.size();
    const uint32_t n = argc > 4 ? (uint32_t)atoi(argv[4]) : 10000, W = argc > 5 ? (uint32_t)atoi(argv[5]) : 16384; const int R = argc > 6 ? atoi(argv[6]) : 20;
    std::mt19937_64 g(20261127ull); std::vector<uint64_t> off(n); for (auto& x : off) x = g() % (orig - W + 1);
    std::mt19937_64 g1(777); std::vector<uint64_t> off1(200); for (auto& x : off1) x = g1() % (orig - W + 1);
    cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, 0)); cudaStream_t s; CK(cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking));
    for (auto& e : g_ev) CK(cudaEventCreate(&e));
    aceapex_gpu_plan* pl = aceapex_gpu_plan_create(a.data(), a.size(), 0);
    if (!pl) { printf("[a1h] %s plan_create failed: %d\n", g_tag, aceapex_gpu_last_error()); return 4; }
    uint64_t v[11]; axw_info(pl, v); const uint64_t bs = v[0], nb = v[1];
    printf("[a1h] %s: archive %zu B, original %llu B (ratio %.4f), block %llu B, blocks %llu, rans jobs %llu, open jobs %llu, raw %llu, chunks %llu/%llu/%llu/%llu, match grid %llu, GPU %s, api %u\n",
           g_tag, a.size(), (unsigned long long)orig, (double)orig / a.size(), (unsigned long long)bs, (unsigned long long)nb, (unsigned long long)v[3], (unsigned long long)v[4],
           (unsigned long long)v[5], (unsigned long long)v[6], (unsigned long long)v[7], (unsigned long long)v[8], (unsigned long long)v[9], (unsigned long long)v[10], p.name, aceapex_gpu_version());
    // device buffers: the archive, n windows, 1 window, the whole file as nb windows of bs
    const uint32_t nf = (uint32_t)nb; std::vector<uint64_t> offf(nf); for (uint32_t b = 0; b < nf; b++) offf[b] = std::min<uint64_t>((uint64_t)b * bs, orig - bs);
    const bool full_ok = bs <= orig && bs <= 0xFFFFFFFFull;
    uint8_t *d_in, *d_out, *d_tmp, *d_tmp1; uint64_t *d_off, *d_o1, *d_off_f = nullptr; int* d_st;
    CK(cudaMalloc(&d_in, a.size())); CK(cudaMemcpy(d_in, a.data(), a.size(), cudaMemcpyHostToDevice));
    const size_t tb = aceapex_gpu_windows_temp_bytes(pl, n, W), tb1 = aceapex_gpu_windows_temp_bytes(pl, 1, W), tbf = full_ok ? aceapex_gpu_windows_temp_bytes(pl, nf, (uint32_t)bs) : 0;
    const size_t outb = std::max<size_t>((size_t)n * W, full_ok ? (size_t)nf * bs : 0);
    CK(cudaMalloc(&d_off, (size_t)n * 8)); CK(cudaMemcpy(d_off, off.data(), (size_t)n * 8, cudaMemcpyHostToDevice));
    CK(cudaMalloc(&d_o1, 8)); CK(cudaMalloc(&d_out, outb)); CK(cudaMalloc(&d_tmp, std::max(tb, tbf))); CK(cudaMalloc(&d_tmp1, tb1)); CK(cudaMalloc(&d_st, 4));
    if (full_ok) { CK(cudaMalloc(&d_off_f, (size_t)nf * 8)); CK(cudaMemcpy(d_off_f, offf.data(), (size_t)nf * 8, cudaMemcpyHostToDevice)); }
    std::vector<uint8_t> h(outb);
    auto call = [&](const uint64_t* doff, uint32_t k, uint32_t w, uint8_t* tmp) {
        if (aceapex_gpu_decompress_windows_async(pl, d_in, doff, k, w, d_out, tmp, d_st, s)) return false; return cudaStreamSynchronize(s) == cudaSuccess; };
    auto status = [&] { int st = -1; CK(cudaMemcpy(&st, d_st, 4, cudaMemcpyDeviceToHost)); return st; };
    const char* vname[3] = {"V0", "V1", "V2"};
    double one_v0 = 0, wps_v0 = 0;
    for (int V = 0; V < 3; V++) {
        axw_variant = V;
        // batch: 2 warm-up, 2 blocks of R (A/A)
        std::vector<double> A, B, all;
        for (int r = 0; r < 2; r++) if (!call(d_off, n, W, d_tmp)) { printf("[a1h] %s %s batch failed\n", g_tag, vname[V]); return 4; }
        for (int blk = 0; blk < 2; blk++) for (int r = 0; r < R; r++) { const double t0 = now_s(); if (!call(d_off, n, W, d_tmp)) return 4; const double t = now_s() - t0; (blk ? B : A).push_back(t); all.push_back(t); }
        const double pa = pct(A, .5), pb = pct(B, .5), p50 = std::min(pa, pb), wps = n / p50;
        const int st = status(); bool ok = true;
        if (V != 1) { CK(cudaMemcpy(h.data(), d_out, (size_t)n * W, cudaMemcpyDeviceToHost)); ok = st == 0 && same(h.data(), o, off.data(), n, W, vname[V]); }
        // single windows (seed 777), each checked
        std::vector<double> one; bool ok1 = true;
        for (int k = 0; k < 200; k++) { CK(cudaMemcpy(d_o1, &off1[k], 8, cudaMemcpyHostToDevice)); const double t0 = now_s();
            if (!call(d_o1, 1, W, d_tmp1)) return 4; one.push_back(now_s() - t0);
            if (V != 1) { CK(cudaMemcpy(h.data(), d_out, W, cudaMemcpyDeviceToHost)); if (status() != 0 || !same(h.data(), o, &off1[k], 1, W, "single")) ok1 = false; } }
        const double one_us = pct(one, .5) * 1e6;
        // the whole file (V0, V2)
        bool okf = true; double full_ms = 0;
        if (V != 1 && full_ok) { const double t0 = now_s(); if (!call(d_off_f, nf, (uint32_t)bs, d_tmp)) return 4; full_ms = (now_s() - t0) * 1e3;
            CK(cudaMemcpy(h.data(), d_out, (size_t)nf * bs, cudaMemcpyDeviceToHost)); okf = status() == 0 && same(h.data(), o, offf.data(), nf, (uint32_t)bs, "whole file"); }
        if (V == 0) { one_v0 = one_us; wps_v0 = wps; }
        const char* eq = V == 1 ? "timing only" : (ok && ok1 && okf ? "all windows + whole file == original" : "DIFFERS");
        printf("[a1h] %s %s batch p50 %.3f ms (A %.3f / B %.3f, A/A %+.1f %%) p99 %.3f ms | %.0f windows/s (x%.3f of V0) | one window %.1f us | whole file %.1f ms | %s\n",
               g_tag, vname[V], p50 * 1e3, pa * 1e3, pb * 1e3, 100 * (pb - pa) / pa, pct(all, .99) * 1e3, wps, wps / wps_v0, one_us, full_ms, eq);
        printf("A1H\t%s\t%s\t%u\t%u\t%llu\t%.3f\t%.3f\t%.3f\t%.1f\t%.0f\t%.3f\t%.1f\t%.1f\t%s\n", g_tag, vname[V], n, W, (unsigned long long)bs, p50 * 1e3, pa * 1e3, pb * 1e3,
               100 * (pb - pa) / pa, wps, wps / wps_v0, one_us, full_ms, V == 1 ? "timing" : (ok && ok1 && okf ? "ok" : "DIFFERS"));
        if (V != 1 && !(ok && ok1 && okf)) g_kill = true;
        // phase breakdown (V0, V2): 20 calls each for n windows and for 1 window, median per phase
        if (V != 1) for (int which = 0; which < 2; which++) {
            const uint32_t k = which ? 1 : n; std::vector<double> ph[6];
            axw_hook = hook;
            for (int r = 0; r < 22; r++) { if (which) CK(cudaMemcpy(d_o1, &off1[r], 8, cudaMemcpyHostToDevice));
                if (!call(which ? d_o1 : d_off, k, W, which ? d_tmp1 : d_tmp)) return 4;
                if (r < 2) continue; for (int q = 0; q < 6; q++) { float ms = 0; CK(cudaEventElapsedTime(&ms, g_ev[q], g_ev[q + 1])); ph[q].push_back(ms); } }
            axw_hook = nullptr;
            static const char* nm[6] = {"init+memset", "fix descriptors", "select", "entropy", "match", "gather+status"};
            double tot = 0; for (int q = 0; q < 6; q++) tot += pct(ph[q], .5);
            printf("[a1h] %s %s phases, %u window(s), GPU time (median of 20) %.1f us:", g_tag, vname[V], k, tot * 1e3);
            for (int q = 0; q < 6; q++) printf(" %s %.1f us (%.0f %%)%s", nm[q], pct(ph[q], .5) * 1e3, 100 * pct(ph[q], .5) / tot, q < 5 ? ";" : "\n");
            printf("A1HPH\t%s\t%s\t%u", g_tag, vname[V], k); for (int q = 0; q < 6; q++) printf("\t%.1f", pct(ph[q], .5) * 1e3); printf("\n");
        }
    }
    // H1: one window by a CUDA Graph of the whole call (V0, V2); the offset buffer is fixed, its content written before
    for (int V : {0, 2}) {
        axw_variant = V; cudaGraph_t gr; cudaGraphExec_t ge;
        CK(cudaStreamBeginCapture(s, cudaStreamCaptureModeThreadLocal));
        const int rc = aceapex_gpu_decompress_windows_async(pl, d_in, d_o1, 1, W, d_out, d_tmp1, d_st, s);
        CK(cudaStreamEndCapture(s, &gr)); if (rc) { printf("[a1h] %s graph capture: call failed %d\n", g_tag, rc); return 4; }
        CK(cudaGraphInstantiate(&ge, gr, 0)); size_t nodes = 0; CK(cudaGraphGetNodes(gr, nullptr, &nodes));
        for (int k = 0; k < 3; k++) { CK(cudaGraphLaunch(ge, s)); CK(cudaStreamSynchronize(s)); }
        std::vector<double> one; bool ok = true;
        for (int k = 0; k < 200; k++) { CK(cudaMemcpy(d_o1, &off1[k], 8, cudaMemcpyHostToDevice)); const double t0 = now_s();
            CK(cudaGraphLaunch(ge, s)); CK(cudaStreamSynchronize(s)); one.push_back(now_s() - t0);
            CK(cudaMemcpy(h.data(), d_out, W, cudaMemcpyDeviceToHost)); if (status() != 0 || !same(h.data(), o, &off1[k], 1, W, "graph")) ok = false; }
        const double us = pct(one, .5) * 1e6;
        printf("[a1h] %s H1 graph %s (%zu nodes): one window p50 %.1f us, p99 %.1f us (x%.3f of V0 calls) | %s\n", g_tag, V ? "V2" : "V0", nodes, us, pct(one, .99) * 1e6,
               one_v0 / us, ok ? "200 windows == original" : "DIFFERS");
        printf("A1HG\t%s\t%s\t%zu\t%.1f\t%.1f\t%.3f\t%s\n", g_tag, V ? "V2" : "V0", nodes, us, pct(one, .99) * 1e6, one_v0 / us, ok ? "ok" : "DIFFERS");
        if (!ok) g_kill = true;
        cudaGraphExecDestroy(ge); cudaGraphDestroy(gr);
    }
    axw_variant = 0;
    if (g_kill) { printf("[a1h] %s KILL: a variant differs from the original - no table\n", g_tag); return 5; }
    printf("[a1h] %s: every compared window == original\n", g_tag);
    return 0;
}
