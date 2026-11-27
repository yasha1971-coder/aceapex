// hybrid1.cu - HYBRID-1 and FULLPOD-1 (measurement branch gpu-a1, never merged): one archive, every CPU core and the
// H100 at once. Full decompression of a genome into pinned host memory:
//   ace  (a) CPU only, aceapex_decompress_mt, all threads; (a') CPU only through aceapex_decompress_ranges (one range per
//        block: the engine the hybrid's CPU part uses); (b) GPU only, block-range plans in batches of K blocks, two
//        streams: the decode of batch i+1 runs while batch i is copied to the host; (c) hybrid: blocks [0, kG) on the GPU
//        pipeline, [kG, nb) on the CPU at the same time, kG = nb x (b) / ((a') + (b))
//   zstd (d) the same three for nvCOMP zstd chunks of C bytes (compressed by nvCOMP on the device, standard zstd frames):
//        CPU part libzstd (ZSTD_decompressDCtx per chunk, a thread pool), GPU part nvCOMP batched, D2H overlapped
// Per configuration: 1 warm-up + R timed runs, median GB/s of output, time to first byte (first batch on the host; a
// one-shot CPU call: its whole time), CPU % of the pod's vCPU (getrusage of this process / wall / vCPU), GPU utilization
// (NVML, sampled every 20 ms). After the last run of each configuration the whole output == the original (memcmp, out of
// the timer) and its XXH3; any difference: KILL, exit 5.
// FULLPOD-1 jobs (one process each, a line per second):
//   fullgpu <open.aet> <original> <secs>      full GPU decodes (on-device XXH3 check, D2H) + windows batches (10 000 x 16 KiB,
//                                             compared on the device with the resident original) on two streams
//   cpucomp <threads> <secs> <file>...        aceapex_compress level 2 in a loop; every archive's XXH3 == the first one's
//   cpudec  <threads> <secs> <arc> <original> aceapex_decompress_mt + aceapex_decompress_ranges (10 000 x 16 KiB) in turn;
//                                             full output XXH3 and every range checked (out of the rate)
// Build: nvcc -std=c++17 -O3 -arch=sm_90 -Isrc -I<nvcomp>/include scripts/hybrid1.cu src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp
//        src/aceapex_api.o -L<nvcomp lib> -l:libnvcomp.so.6 -lzstd -lnvidia-ml -lpthread -o hybrid1
//        (src/aceapex_api.o: g++ -std=c++17 -O3 -march=native -Isrc -c src/aceapex_api.cpp)
#include "aceapex.h"
#include "aceapex_gpu.h"
#include <nvcomp/zstd.h>
#include <zstd.h>
#include <nvml.h>
#define XXH_INLINE_ALL
#include "xxhash.h"
#include <cuda_runtime.h>
#include <sys/resource.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <thread>
#include <vector>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { printf("CUDA %s @%d: %s\n", #x, __LINE__, cudaGetErrorString(e_)); exit(2); } } while (0)
#define NV(x) do { nvcompStatus_t s_ = (x); if (s_ != nvcompSuccess) { printf("nvcomp %s @%d: status %d\n", #x, __LINE__, (int)s_); exit(3); } } while (0)
static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static std::vector<uint8_t> slurp(const char* p) {
    std::vector<uint8_t> v; FILE* f = fopen(p, "rb"); if (!f) { perror(p); exit(1); }
    fseek(f, 0, SEEK_END); v.resize((size_t)ftell(f)); fseek(f, 0, SEEK_SET);
    if (!v.empty() && fread(v.data(), 1, v.size(), f) != v.size()) { perror(p); exit(1); } fclose(f); return v; }
static double med(std::vector<double> v) { if (v.empty()) return 0; std::sort(v.begin(), v.end()); return v[v.size() / 2]; }
static double cpu_s() { rusage u; getrusage(RUSAGE_SELF, &u); return u.ru_utime.tv_sec + u.ru_utime.tv_usec * 1e-6 + u.ru_stime.tv_sec + u.ru_stime.tv_usec * 1e-6; }
static int g_vcpu = 1; static const char* g_tag = ""; static bool g_kill = false;

// NVML sampler: GPU utilization (%) averaged over [start, stop)
struct GpuSampler {
    nvmlDevice_t dev{}; bool ok = false; std::atomic<bool> run{false}; std::thread th; double sum = 0, msum = 0; long n = 0;
    GpuSampler() { ok = nvmlInit() == NVML_SUCCESS && nvmlDeviceGetHandleByIndex(0, &dev) == NVML_SUCCESS; }
    void start() { sum = msum = 0; n = 0; if (!ok) return; run = true; th = std::thread([this] { while (run) { nvmlUtilization_t u;
        if (nvmlDeviceGetUtilizationRates(dev, &u) == NVML_SUCCESS) { sum += u.gpu; msum += u.memory; n++; } std::this_thread::sleep_for(std::chrono::milliseconds(20)); } }); }
    void stop() { if (!ok) return; run = false; th.join(); }
    double gpu() const { return n ? sum / n : -1; } double mem() const { return n ? msum / n : -1; }
};
static GpuSampler* g_smp;

struct Res { double gbps, ttfb_ms, cpu_pct, gpu_pct; };
// fn(ttfb_s&) runs one full decode into the host buffer and returns false on an error
template <class F> static Res measure(F fn, int R, uint64_t bytes) {
    double tf; if (!fn(tf)) { printf("[hy] %s warm-up failed\n", g_tag); exit(4); }
    std::vector<double> t, f; const double c0 = cpu_s(), w0 = now_s(); g_smp->start();
    for (int r = 0; r < R; r++) { const double a = now_s(); if (!fn(tf)) { printf("[hy] %s run failed\n", g_tag); exit(4); } t.push_back(now_s() - a); f.push_back(tf); }
    g_smp->stop(); const double w = now_s() - w0, c = cpu_s() - c0;
    return {bytes / med(t) / 1e9, med(f) * 1e3, 100.0 * c / w / g_vcpu, g_smp->gpu()};
}
static void verify_row(const char* codec, const char* cfg, uint64_t size, const Res& r, const std::string& split, const uint8_t* out, const std::vector<uint8_t>& o) {
    const bool ok = memcmp(out, o.data(), o.size()) == 0; const uint64_t h = XXH3_64bits(out, o.size());
    printf("[hy] %s %-5s %-14s size %12llu B | %7.2f GB/s | first byte %8.2f ms | CPU %5.1f %% of %d vCPU | GPU %5.1f %% | %s | XXH3 %016llx %s\n",
           g_tag, codec, cfg, (unsigned long long)size, r.gbps, r.ttfb_ms, r.cpu_pct, g_vcpu, r.gpu_pct, split.c_str(), (unsigned long long)h, ok ? "== original" : "DIFFERS");
    printf("HYROW\t%s\t%s\t%s\t%llu\t%.3f\t%.2f\t%.1f\t%.1f\t%s\t%016llx\t%s\n", g_tag, codec, cfg, (unsigned long long)size, r.gbps, r.ttfb_ms, r.cpu_pct, r.gpu_pct,
           split.c_str(), (unsigned long long)h, ok ? "ok" : "DIFFERS");
    if (!ok) g_kill = true;
}

// ------------------------------------------------------------------ ACE: GPU pipeline over block-range plans
struct AceGpu {
    std::vector<aceapex_gpu_plan*> pl; std::vector<uint32_t> b0; std::vector<uint64_t> lo; uint8_t* d_arc = nullptr;
    uint8_t* d_out[2]{}; uint8_t* d_tmp[2]{}; int* d_st = nullptr; cudaStream_t st[2]; cudaEvent_t ev0; uint64_t bs = 0, orig = 0;
    void build(const std::vector<uint8_t>& a, uint32_t first, uint32_t last, uint32_t K) {   // plans of [first, last) in batches of K
        for (auto* p : pl) aceapex_gpu_plan_destroy(p); pl.clear(); b0.clear(); lo.clear();
        size_t mo = 0, mt = 0;
        for (uint32_t b = first; b < last; b += K) { const uint32_t e = std::min(last, b + K);
            aceapex_gpu_plan* p = aceapex_gpu_plan_create_blocks(a.data(), a.size(), b, e, 0); if (!p) { printf("[hy] plan [%u,%u) failed %d\n", b, e, aceapex_gpu_last_error()); exit(4); }
            uint64_t l, h; aceapex_gpu_plan_input_window(p, &l, &h); pl.push_back(p); b0.push_back(b); lo.push_back(l);
            mo = std::max(mo, aceapex_gpu_output_bytes(p)); mt = std::max(mt, aceapex_gpu_temp_bytes(p)); }
        for (int i = 0; i < 2; i++) { if (d_out[i]) { cudaFree(d_out[i]); cudaFree(d_tmp[i]); } CK(cudaMalloc(&d_out[i], mo + 64)); CK(cudaMalloc(&d_tmp[i], mt + 256)); }
        if (d_st) cudaFree(d_st); CK(cudaMalloc(&d_st, 4 * (pl.size() + 1)));
    }
    bool run(uint8_t* h_out, double& ttfb, double t0) {   // the batches into h_out at their block offsets
        CK(cudaMemsetAsync(d_st, 0, 4 * pl.size(), st[0])); CK(cudaStreamSynchronize(st[0]));
        for (size_t i = 0; i < pl.size(); i++) { const int s = (int)(i & 1);
            if (aceapex_gpu_decompress_async(pl[i], d_arc + lo[i], d_out[s], d_tmp[s], d_st + i, 0, st[s])) return false;
            CK(cudaMemcpyAsync(h_out + (uint64_t)b0[i] * bs, d_out[s], aceapex_gpu_output_bytes(pl[i]), cudaMemcpyDeviceToHost, st[s]));
            if (i == 0) CK(cudaEventRecord(ev0, st[0])); }
        if (!pl.empty()) { CK(cudaEventSynchronize(ev0)); ttfb = now_s() - t0; }
        CK(cudaStreamSynchronize(st[0])); CK(cudaStreamSynchronize(st[1]));
        std::vector<int> s(pl.size()); CK(cudaMemcpy(s.data(), d_st, 4 * pl.size(), cudaMemcpyDeviceToHost));
        for (int x : s) if (x) { printf("[hy] gpu status %d\n", x); return false; }
        return true;
    }
};
// ACE CPU part: one range per block of [first, last) through aceapex_decompress_ranges
static bool ace_cpu_ranges(const std::vector<uint8_t>& a, uint64_t bs, uint64_t orig, uint32_t first, uint32_t last, uint8_t* h_out, int thr) {
    if (first >= last) return true;
    std::vector<aceapex_range_t> r(last - first);
    for (uint32_t b = first; b < last; b++) { const uint64_t o = (uint64_t)b * bs; r[b - first] = {o, std::min(bs, orig - o), h_out + o, 0}; }
    const int64_t k = aceapex_decompress_ranges(a.data(), a.size(), r.data(), r.size(), thr);
    if (k != (int64_t)r.size()) { printf("[hy] ranges returned %lld of %zu\n", (long long)k, r.size()); return false; }
    return true;
}
static void mode_ace(const char* arcp, const std::vector<uint8_t>& o, uint8_t* h_out, int R, uint32_t K) {
    const std::vector<uint8_t> a = slurp(arcp);
    aceapex_gpu_plan* one = aceapex_gpu_plan_create_blocks(a.data(), a.size(), 0, 1, 0);   // the block size = the window of block 0
    if (!one) { printf("[hy] plan failed %d\n", aceapex_gpu_last_error()); exit(4); }
    const uint64_t bs = aceapex_gpu_output_bytes(one), orig = o.size(); const uint32_t nb = (uint32_t)((orig + bs - 1) / bs); aceapex_gpu_plan_destroy(one);
    printf("[hy] %s ace: archive %zu B (ratio %.4f), block %llu B, %u blocks, batch %u blocks\n", g_tag, a.size(), (double)orig / a.size(), (unsigned long long)bs, nb, K);
    AceGpu G; G.bs = bs; G.orig = orig; CK(cudaMalloc(&G.d_arc, a.size())); CK(cudaMemcpy(G.d_arc, a.data(), a.size(), cudaMemcpyHostToDevice));
    CK(cudaStreamCreateWithFlags(&G.st[0], cudaStreamNonBlocking)); CK(cudaStreamCreateWithFlags(&G.st[1], cudaStreamNonBlocking)); CK(cudaEventCreate(&G.ev0));
    // (a) CPU only, decompress_mt
    memset(h_out, 0, orig);
    Res ra = measure([&](double& tf) { const double t0 = now_s(); const bool ok = aceapex_decompress_mt(a.data(), a.size(), h_out, orig, g_vcpu) == (int64_t)orig; tf = now_s() - t0; return ok; }, R, orig);
    verify_row("ace", "cpu_mt", a.size(), ra, "cpu all", h_out, o);
    // (a') CPU only, ranges (the hybrid's CPU engine)
    memset(h_out, 0, orig);
    Res rr = measure([&](double& tf) { const double t0 = now_s(); const bool ok = ace_cpu_ranges(a, bs, orig, 0, nb, h_out, g_vcpu); tf = now_s() - t0; return ok; }, R, orig);
    verify_row("ace", "cpu_ranges", a.size(), rr, "cpu all", h_out, o);
    // (b) GPU only
    memset(h_out, 0, orig); G.build(a, 0, nb, K);
    Res rb = measure([&](double& tf) { return G.run(h_out, tf, now_s()); }, R, orig);
    verify_row("ace", "gpu", a.size(), rb, "gpu all", h_out, o);
    // (c) hybrid, split by (a') and (b)
    const double cpu_eng = rr.gbps;   // the CPU part of the hybrid runs the ranges engine
    uint32_t kG = (uint32_t)std::min<double>(nb, std::max(0.0, nb * rb.gbps / (cpu_eng + rb.gbps) + 0.5));
    memset(h_out, 0, orig); G.build(a, 0, kG, K);
    Res rc = measure([&](double& tf) { const double t0 = now_s(); std::atomic<double> tcpu{1e9}; bool okc = true;
        std::thread th([&] { okc = ace_cpu_ranges(a, bs, orig, kG, nb, h_out, std::max(1, g_vcpu - 1)); tcpu = now_s() - t0; });
        double tg = 1e9; const bool okg = G.run(h_out, tg, t0); th.join(); tf = std::min(tg, tcpu.load()); return okg && okc; }, R, orig);
    char sp[96]; snprintf(sp, sizeof sp, "gpu blocks [0,%u) cpu [%u,%u) %d thr", kG, kG, nb, std::max(1, g_vcpu - 1));
    verify_row("ace", "hybrid", a.size(), rc, sp, h_out, o);
    printf("[hy] %s ace hybrid / ((a') + (b)) = %.3f ; hybrid / ((a) + (b)) = %.3f\n", g_tag, rc.gbps / (rr.gbps + rb.gbps), rc.gbps / (ra.gbps + rb.gbps));
    printf("HYSUM\t%s\tace\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\n", g_tag, ra.gbps, rr.gbps, rb.gbps, rc.gbps, rc.gbps / (rr.gbps + rb.gbps), rc.gbps / (ra.gbps + rb.gbps));
    for (auto* p : G.pl) aceapex_gpu_plan_destroy(p);
    cudaFree(G.d_arc); for (int i = 0; i < 2; i++) { cudaFree(G.d_out[i]); cudaFree(G.d_tmp[i]); } cudaFree(G.d_st);
}

// ------------------------------------------------------------------ nvCOMP zstd chunks: CPU libzstd, GPU nvCOMP, hybrid
static void mode_zstd(const std::vector<uint8_t>& o, uint8_t* h_out, int R, size_t C) {
    const uint64_t orig = o.size(); const size_t N = (orig + C - 1) / C; cudaStream_t s0, s1; CK(cudaStreamCreateWithFlags(&s0, cudaStreamNonBlocking)); CK(cudaStreamCreateWithFlags(&s1, cudaStreamNonBlocking));
    // compression on the device (setup): as scripts/gpu_a1.cu
    uint8_t* d_orig; CK(cudaMalloc(&d_orig, orig)); CK(cudaMemcpy(d_orig, o.data(), orig, cudaMemcpyHostToDevice));
    std::vector<void*> hp(N); std::vector<size_t> hs(N);
    for (size_t i = 0; i < N; i++) { hp[i] = d_orig + i * C; hs[i] = std::min(C, (size_t)(orig - i * C)); }
    size_t maxc = 0, ctemp = 0; NV(nvcompBatchedZstdCompressGetMaxOutputChunkSize(C, nvcompBatchedZstdCompressDefaultOpts, &maxc));
    NV(nvcompBatchedZstdCompressGetTempSize(N, C, nvcompBatchedZstdCompressDefaultOpts, &ctemp, orig, s0));
    void **d_up, **d_cp; size_t *d_us, *d_cs; uint8_t *d_cbuf, *d_ctmp; nvcompStatus_t* d_cst;
    CK(cudaMalloc(&d_up, N * 8)); CK(cudaMalloc(&d_us, N * 8)); CK(cudaMalloc(&d_cp, N * 8)); CK(cudaMalloc(&d_cs, N * 8)); CK(cudaMalloc(&d_cst, N * sizeof(nvcompStatus_t)));
    CK(cudaMalloc(&d_cbuf, N * maxc)); CK(cudaMalloc(&d_ctmp, ctemp ? ctemp : 1));
    std::vector<void*> hcp(N); for (size_t i = 0; i < N; i++) hcp[i] = d_cbuf + i * maxc;
    CK(cudaMemcpy(d_up, hp.data(), N * 8, cudaMemcpyHostToDevice)); CK(cudaMemcpy(d_us, hs.data(), N * 8, cudaMemcpyHostToDevice)); CK(cudaMemcpy(d_cp, hcp.data(), N * 8, cudaMemcpyHostToDevice));
    NV(nvcompBatchedZstdCompressAsync((const void* const*)d_up, d_us, C, N, d_ctmp, ctemp, d_cp, d_cs, nvcompBatchedZstdCompressDefaultOpts, d_cst, s0)); CK(cudaStreamSynchronize(s0));
    std::vector<size_t> cs(N); CK(cudaMemcpy(cs.data(), d_cs, N * 8, cudaMemcpyDeviceToHost));
    std::vector<uint64_t> coff(N + 1, 0); for (size_t i = 0; i < N; i++) coff[i + 1] = coff[i] + cs[i];
    std::vector<uint8_t> arch(coff[N]); for (size_t i = 0; i < N; i++) CK(cudaMemcpy(arch.data() + coff[i], hcp[i], cs[i], cudaMemcpyDeviceToHost));
    cudaFree(d_orig); cudaFree(d_up); cudaFree(d_us); cudaFree(d_cp); cudaFree(d_cs); cudaFree(d_cst); cudaFree(d_cbuf); cudaFree(d_ctmp);
    const uint64_t size = coff[N] + 8 * (N + 1);
    printf("[hy] %s zstd: chunk %zu B, %zu chunks, archive %llu B (ratio %.4f)\n", g_tag, C, N, (unsigned long long)size, (double)orig / size);
    // the frames on the device once; pointer tables for every chunk (input) and, per batch, the slot outputs
    const size_t K = std::max<size_t>(1, ((size_t)256 << 20) / C);   // 256 MiB of output per batch
    uint8_t* d_arch; CK(cudaMalloc(&d_arch, arch.size())); CK(cudaMemcpy(d_arch, arch.data(), arch.size(), cudaMemcpyHostToDevice));
    std::vector<void*> ip(N), op(N); std::vector<size_t> isz(N), osz(N);
    uint8_t* d_slot[2]; CK(cudaMalloc(&d_slot[0], K * C)); CK(cudaMalloc(&d_slot[1], K * C));
    for (size_t i = 0; i < N; i++) { ip[i] = d_arch + coff[i]; isz[i] = cs[i]; osz[i] = std::min(C, (size_t)(orig - i * C)); const size_t bi = i / K; op[i] = d_slot[bi & 1] + (i - bi * K) * C; }
    void **d_ip, **d_op; size_t *d_isz, *d_osz, *d_act; nvcompStatus_t* d_jst;
    CK(cudaMalloc(&d_ip, N * 8)); CK(cudaMalloc(&d_op, N * 8)); CK(cudaMalloc(&d_isz, N * 8)); CK(cudaMalloc(&d_osz, N * 8)); CK(cudaMalloc(&d_act, N * 8)); CK(cudaMalloc(&d_jst, N * sizeof(nvcompStatus_t)));
    CK(cudaMemcpy(d_ip, ip.data(), N * 8, cudaMemcpyHostToDevice)); CK(cudaMemcpy(d_op, op.data(), N * 8, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_isz, isz.data(), N * 8, cudaMemcpyHostToDevice)); CK(cudaMemcpy(d_osz, osz.data(), N * 8, cudaMemcpyHostToDevice));
    size_t dt = 0; NV(nvcompBatchedZstdDecompressGetTempSize(K, C, nvcompBatchedZstdDecompressDefaultOpts, &dt, K * C, s0));
    uint8_t* d_dt[2]; CK(cudaMalloc(&d_dt[0], dt ? dt : 1)); CK(cudaMalloc(&d_dt[1], dt ? dt : 1));
    cudaStream_t st[2] = {s0, s1}; cudaEvent_t ev0; CK(cudaEventCreate(&ev0));
    auto gpu = [&](size_t c0, size_t c1, double& ttfb, double t0) {   // chunks [c0, c1): batches aligned to K (their slot pointers)
        bool first = true;
        for (size_t b = c0 / K * K; b < c1; b += K) { const size_t lo = std::max(b, c0), hi = std::min(c1, b + K), n = hi - lo; const int s = (int)((b / K) & 1);
            if (nvcompBatchedZstdDecompressAsync((const void* const*)(d_ip + lo), d_isz + lo, d_osz + lo, d_act + lo, n, d_dt[s], dt, (void* const*)(d_op + lo),
                                                 nvcompBatchedZstdDecompressDefaultOpts, d_jst + lo, st[s]) != nvcompSuccess) return false;
            const uint64_t ob = (uint64_t)lo * C, oe = std::min<uint64_t>(orig, (uint64_t)hi * C);
            CK(cudaMemcpyAsync(h_out + ob, d_slot[s] + (lo - b) * C, oe - ob, cudaMemcpyDeviceToHost, st[s]));
            if (first) { CK(cudaEventRecord(ev0, st[s])); first = false; } }
        if (!first) { CK(cudaEventSynchronize(ev0)); ttfb = now_s() - t0; }
        CK(cudaStreamSynchronize(s0)); CK(cudaStreamSynchronize(s1));
        if (c1 > c0) { std::vector<nvcompStatus_t> js(c1 - c0); CK(cudaMemcpy(js.data(), d_jst + c0, (c1 - c0) * sizeof(nvcompStatus_t), cudaMemcpyDeviceToHost));
            for (auto x : js) if (x != nvcompSuccess) { printf("[hy] nvcomp chunk status %d\n", (int)x); return false; } }
        return true; };
    auto cpu = [&](size_t c0, size_t c1, int thr) {   // libzstd, chunks grabbed 64 at a time
        std::atomic<size_t> nx{c0}; std::atomic<bool> ok{true}; std::vector<std::thread> th;
        for (int t = 0; t < thr; t++) th.emplace_back([&] { ZSTD_DCtx* z = ZSTD_createDCtx();
            for (size_t g; (g = nx.fetch_add(64)) < c1; ) for (size_t i = g; i < std::min(c1, g + 64); i++) {
                const size_t r = ZSTD_decompressDCtx(z, h_out + i * C, osz[i], arch.data() + coff[i], cs[i]); if (ZSTD_isError(r) || r != osz[i]) ok = false; }
            ZSTD_freeDCtx(z); });
        for (auto& x : th) x.join(); return ok.load(); };
    char cfg[32];
    memset(h_out, 0, orig);
    Res ra = measure([&](double& tf) { const double t0 = now_s(); const bool ok = cpu(0, N, g_vcpu); tf = now_s() - t0; return ok; }, R, orig);
    snprintf(cfg, sizeof cfg, "cpu_%zuk", C >> 10); verify_row("zstd", cfg, size, ra, "cpu all", h_out, o);
    memset(h_out, 0, orig);
    Res rb = measure([&](double& tf) { return gpu(0, N, tf, now_s()); }, R, orig);
    snprintf(cfg, sizeof cfg, "gpu_%zuk", C >> 10); verify_row("zstd", cfg, size, rb, "gpu all", h_out, o);
    const size_t kG = (size_t)std::min<double>(N, std::max(0.0, N * rb.gbps / (ra.gbps + rb.gbps) + 0.5));
    memset(h_out, 0, orig);
    Res rc = measure([&](double& tf) { const double t0 = now_s(); std::atomic<double> tcpu{1e9}; bool okc = true;
        std::thread th([&] { okc = cpu(kG, N, std::max(1, g_vcpu - 1)); tcpu = now_s() - t0; });
        double tg = 1e9; const bool okg = gpu(0, kG, tg, t0); th.join(); tf = std::min(tg, tcpu.load()); return okg && okc; }, R, orig);
    char sp[96]; snprintf(sp, sizeof sp, "gpu chunks [0,%zu) cpu [%zu,%zu) %d thr", kG, kG, N, std::max(1, g_vcpu - 1));
    snprintf(cfg, sizeof cfg, "hybrid_%zuk", C >> 10); verify_row("zstd", cfg, size, rc, sp, h_out, o);
    printf("HYSUM\t%s\tzstd_%zuk\t%.3f\t-\t%.3f\t%.3f\t%.3f\t-\n", g_tag, C >> 10, ra.gbps, rb.gbps, rc.gbps, rc.gbps / (ra.gbps + rb.gbps));
    cudaFree(d_arch); cudaFree(d_slot[0]); cudaFree(d_slot[1]); cudaFree(d_ip); cudaFree(d_op); cudaFree(d_isz); cudaFree(d_osz); cudaFree(d_act); cudaFree(d_jst);
    cudaFree(d_dt[0]); cudaFree(d_dt[1]); cudaStreamDestroy(s0); cudaStreamDestroy(s1);
}

// ------------------------------------------------------------------ FULLPOD-1 jobs
__global__ void k_cmpwin(const uint8_t* got, const uint8_t* orig, const uint64_t* off, uint32_t W, unsigned long long* bad) {
    const uint32_t i = blockIdx.x; const uint64_t o = off[i]; unsigned long long b = 0;
    for (uint32_t k = threadIdx.x; k < W; k += blockDim.x) b += got[(uint64_t)i * W + k] != orig[o + k];
    if (b) atomicAdd(bad, b); }
static int job_fullgpu(const char* arcp, const char* origp, double secs, int d2h) {   // d2h 0: data and result stay in VRAM
    const std::vector<uint8_t> a = slurp(arcp), o = slurp(origp); const uint64_t orig = o.size(); const uint32_t n = 10000, W = 16384;
    aceapex_gpu_plan* pl = aceapex_gpu_plan_create(a.data(), a.size(), 0); if (!pl) { printf("FP\tfullgpu\tplan failed\n"); return 4; }
    uint8_t *d_in, *d_out, *d_tmp, *d_orig, *d_wout, *d_wtmp, *h_out; int *d_st, *d_wst; uint64_t* d_off; unsigned long long* d_bad;
    CK(cudaMalloc(&d_in, a.size())); CK(cudaMemcpy(d_in, a.data(), a.size(), cudaMemcpyHostToDevice));
    CK(cudaMalloc(&d_out, orig)); CK(cudaMalloc(&d_tmp, aceapex_gpu_temp_bytes(pl))); CK(cudaMalloc(&d_orig, orig)); CK(cudaMemcpy(d_orig, o.data(), orig, cudaMemcpyHostToDevice));
    CK(cudaMalloc(&d_wout, (size_t)n * W)); CK(cudaMalloc(&d_wtmp, aceapex_gpu_windows_temp_bytes(pl, n, W))); CK(cudaMalloc(&d_st, 4)); CK(cudaMalloc(&d_wst, 4));
    CK(cudaMalloc(&d_off, (size_t)n * 8)); CK(cudaMalloc(&d_bad, 8)); CK(cudaMemset(d_bad, 0, 8)); CK(cudaHostAlloc(&h_out, orig, 0));
    std::mt19937_64 g(20261127ull); std::vector<uint64_t> off(n); for (auto& x : off) x = g() % (orig - W + 1); CK(cudaMemcpy(d_off, off.data(), (size_t)n * 8, cudaMemcpyHostToDevice));
    cudaStream_t sa, sb; CK(cudaStreamCreateWithFlags(&sa, cudaStreamNonBlocking)); CK(cudaStreamCreateWithFlags(&sb, cudaStreamNonBlocking));
    std::atomic<bool> stop{false}; std::atomic<uint64_t> dec{0}, win{0}, badst{0};
    std::thread tb([&] { while (!stop) { if (aceapex_gpu_decompress_windows_async(pl, d_in, d_off, n, W, d_wout, d_wtmp, d_wst, sb)) { badst++; break; }
        k_cmpwin<<<n, 256, 0, sb>>>(d_wout, d_orig, d_off, W, d_bad); int st = 0; cudaMemcpyAsync(&st, d_wst, 4, cudaMemcpyDeviceToHost, sb); cudaStreamSynchronize(sb); if (st) badst++; win += n; } });
    const double t0 = now_s(); double last = t0; uint64_t ld = 0, lw = 0;
    while (now_s() - t0 < secs) {
        if (aceapex_gpu_decompress_async(pl, d_in, d_out, d_tmp, d_st, ACEAPEX_GPU_VERIFY_XXH3, sa)) { badst++; break; }
        if (d2h) CK(cudaMemcpyAsync(h_out, d_out, orig, cudaMemcpyDeviceToHost, sa)); int st = 0; CK(cudaMemcpyAsync(&st, d_st, 4, cudaMemcpyDeviceToHost, sa)); CK(cudaStreamSynchronize(sa));
        if (st) badst++; dec += orig;
        const double t = now_s(); if (t - last >= 1.0) { const uint64_t d = dec, w = win;
            printf("FP\tfullgpu%s\t%.1f\tdecode_GBps\t%.3f\twindows_per_s\t%.0f\n", d2h ? "" : "_vram", t - t0, (d - ld) / (t - last) / 1e9, (w - lw) / (t - last)); ld = d; lw = w; last = t; } }
    stop = true; tb.join(); const double T = now_s() - t0; unsigned long long bad = 0; CK(cudaMemcpy(&bad, d_bad, 8, cudaMemcpyDeviceToHost));
    if (!d2h) CK(cudaMemcpy(h_out, d_out, orig, cudaMemcpyDeviceToHost));   // VRAM mode: the last decode copied once, out of the window
    const bool hok = memcmp(h_out, o.data(), orig) == 0;   // the last full decode on the host
    printf("FPEND\tfullgpu%s\t%.1f\tdecode_GBps\t%.3f\twindows_per_s\t%.0f\tstatus_bad\t%llu\twindow_bytes_bad\t%llu\tlast_host_copy\t%s\n", d2h ? "" : "_vram", T, dec / T / 1e9, win / T,
           (unsigned long long)badst.load(), bad, hok ? "ok" : "DIFFERS");
    return (badst || bad || !hok) ? 5 : 0;
}
static int job_cpucomp(int thr, double secs, int nf, char** files) {
    std::vector<std::vector<uint8_t>> in; for (int i = 0; i < nf; i++) in.push_back(slurp(files[i]));
    std::vector<uint64_t> first(nf, 0); std::vector<uint8_t> out; uint64_t bytes = 0, lb = 0, bad = 0;
    for (int i = 0; i < nf; i++) {   // before the timer: each file once, its archive decoded and compared, its XXH3 kept
        out.resize(aceapex_compress_bound(in[i].size())); const int64_t z = aceapex_compress(in[i].data(), in[i].size(), out.data(), out.size(), 2, thr);
        std::vector<uint8_t> rt(in[i].size()); const bool ok = z > 0 && aceapex_decompress_mt(out.data(), (size_t)z, rt.data(), rt.size(), thr) == (int64_t)rt.size() && rt == in[i];
        first[i] = z > 0 ? XXH3_64bits(out.data(), (size_t)z) : 0; printf("FP\tcpucomp\troundtrip\t%s\t%lld\t%s\n", files[i], (long long)z, ok ? "ok" : "DIFFERS"); if (!ok) return 5; }
    const double t0 = now_s(); double last = t0;
    for (int it = 0; now_s() - t0 < secs; it++) { const int i = it % nf;
        out.resize(aceapex_compress_bound(in[i].size())); const int64_t z = aceapex_compress(in[i].data(), in[i].size(), out.data(), out.size(), 2, thr);
        if (z <= 0) { bad++; break; } if (XXH3_64bits(out.data(), (size_t)z) != first[i]) bad++;
        bytes += in[i].size(); const double t = now_s();
        if (t - last >= 1.0) { printf("FP\tcpucomp\t%.1f\tMBps\t%.1f\n", t - t0, (bytes - lb) / (t - last) / 1e6); lb = bytes; last = t; } }
    const double T = now_s() - t0; printf("FPEND\tcpucomp\t%.1f\tMBps\t%.1f\tbad\t%llu\n", T, bytes / T / 1e6, (unsigned long long)bad); return bad ? 5 : 0;
}
static int job_cpudec(int thr, double secs, const char* arcp, const char* origp) {
    const std::vector<uint8_t> a = slurp(arcp), o = slurp(origp); const uint64_t orig = o.size(), H = XXH3_64bits(o.data(), orig); const uint32_t n = 10000, W = 16384;
    std::vector<uint8_t> out(orig), win((size_t)n * W); std::mt19937_64 g(20261127ull); std::vector<aceapex_range_t> r(n);
    for (uint32_t i = 0; i < n; i++) { const uint64_t x = g() % (orig - W + 1); r[i] = {x, W, win.data() + (size_t)i * W, 0}; }
    uint64_t dec = 0, rq = 0, ld = 0, lr = 0, bad = 0; double bd = 0, br = 0; const double t0 = now_s(); double last = t0;
    for (int it = 0; now_s() - t0 < secs; it++) {
        const double a0 = now_s();
        if (it & 1) { const int64_t k = aceapex_decompress_ranges(a.data(), a.size(), r.data(), n, thr); br += now_s() - a0; if (k != n) bad++;
                      for (uint32_t i = 0; i < n; i++) if (memcmp(win.data() + (size_t)i * W, o.data() + r[i].offset, W)) { bad++; break; } rq += n; }
        else { const int64_t k = aceapex_decompress_mt(a.data(), a.size(), out.data(), orig, thr); bd += now_s() - a0; if (k != (int64_t)orig || XXH3_64bits(out.data(), orig) != H) bad++; dec += orig; }
        const double t = now_s(); if (t - last >= 1.0) { printf("FP\tcpudec\t%.1f\tdecode_GBps\t%.3f\tranges_per_s\t%.0f\n", t - t0, (dec - ld) / (t - last) / 1e9, (rq - lr) / (t - last));
            ld = dec; lr = rq; last = t; } }
    const double T = now_s() - t0;
    printf("FPEND\tcpudec\t%.1f\tdecode_GBps\t%.3f\tranges_per_s\t%.0f\tdecode_GBps_busy\t%.3f\tranges_per_s_busy\t%.0f\tbad\t%llu\n", T, dec / T / 1e9, rq / T,
           bd > 0 ? dec / bd / 1e9 : 0, br > 0 ? rq / br : 0, (unsigned long long)bad); return bad ? 5 : 0;
}

// step 0 (word of Yakiv 06:52): PCIe H2D / D2H, pinned and pageable, 64 MiB - 1 GiB (median of 10 copies, events)
static int mode_pcie() {
    const size_t MX = (size_t)1 << 30; uint8_t *d, *hp, *hq; CK(cudaMalloc(&d, MX)); CK(cudaHostAlloc(&hp, MX, 0)); hq = (uint8_t*)malloc(MX); memset(hp, 1, MX); memset(hq, 1, MX);
    cudaEvent_t a, b; CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
    for (size_t sz : {(size_t)64 << 20, (size_t)256 << 20, (size_t)1 << 30}) for (int pin = 1; pin >= 0; pin--) for (int dir = 0; dir < 2; dir++) {
        uint8_t* h = pin ? hp : hq; std::vector<double> t;
        for (int r = 0; r < 12; r++) { CK(cudaEventRecord(a)); if (dir == 0) CK(cudaMemcpy(d, h, sz, cudaMemcpyHostToDevice)); else CK(cudaMemcpy(h, d, sz, cudaMemcpyDeviceToHost));
            CK(cudaEventRecord(b)); CK(cudaEventSynchronize(b)); float ms; CK(cudaEventElapsedTime(&ms, a, b)); if (r >= 2) t.push_back(ms / 1e3); }
        printf("PCIE\t%s\t%s\t%zu MiB\t%.2f GB/s\n", dir ? "D2H" : "H2D", pin ? "pinned" : "pageable", sz >> 20, sz / med(t) / 1e9); }
    cudaFree(d); cudaFreeHost(hp); free(hq); return 0;
}
// step 0: host memory copy, 1 GiB per thread pair of buffers, threads 1 / N/2 / N (median of 5)
static int mode_memcpy(int N) {
    const size_t SZ = (size_t)1 << 30;
    for (int T : {1, std::max(1, N / 2), N}) {
        std::vector<uint8_t*> src(T), dst(T); for (int i = 0; i < T; i++) { src[i] = (uint8_t*)malloc(SZ / T); dst[i] = (uint8_t*)malloc(SZ / T); memset(src[i], 1, SZ / T); memset(dst[i], 0, SZ / T); }
        std::vector<double> t;
        for (int r = 0; r < 6; r++) { const double a = now_s(); std::vector<std::thread> th; for (int i = 0; i < T; i++) th.emplace_back([&, i] { memcpy(dst[i], src[i], SZ / T); });
            for (auto& x : th) x.join(); if (r) t.push_back(now_s() - a); }
        printf("MEMCPY\tthreads %d\t%.2f GB/s (copied bytes / s; read + write = 2x)\n", T, SZ / med(t) / 1e9);
        for (int i = 0; i < T; i++) { free(src[i]); free(dst[i]); } }
    return 0;
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc >= 2 && !strcmp(argv[1], "pcie")) return mode_pcie();
    if (argc >= 3 && !strcmp(argv[1], "memcpy")) return mode_memcpy(atoi(argv[2]));
    if (argc >= 2 && !strcmp(argv[1], "fullgpu") && argc >= 5) return job_fullgpu(argv[2], argv[3], atof(argv[4]), argc > 5 ? atoi(argv[5]) : 1);
    if (argc >= 2 && !strcmp(argv[1], "cpucomp") && argc >= 5) return job_cpucomp(atoi(argv[2]), atof(argv[3]), argc - 4, argv + 4);
    if (argc >= 2 && !strcmp(argv[1], "cpudec") && argc >= 6) return job_cpudec(atoi(argv[2]), atof(argv[3]), argv[4], argv[5]);
    if (argc < 5) { fprintf(stderr, "usage: %s hybrid <tag> <open.aet> <original> [vcpu] [R] [K blocks]\n       %s fullgpu|cpucomp|cpudec ...\n", argv[0], argv[0]); return 1; }
    g_tag = argv[2]; g_vcpu = argc > 5 ? atoi(argv[5]) : (int)std::thread::hardware_concurrency(); const int R = argc > 6 ? atoi(argv[6]) : 5; const uint32_t K = argc > 7 ? atoi(argv[7]) : 256;
    const std::vector<uint8_t> o = slurp(argv[4]); uint8_t* h_out; CK(cudaHostAlloc(&h_out, o.size(), 0));
    GpuSampler smp; g_smp = &smp; cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, 0));
    printf("[hy] %s: original %zu B, GPU %s, vCPU %d, repeats %d, NVML %s, libzstd %s\n", g_tag, o.size(), p.name, g_vcpu, R, smp.ok ? "ok" : "off", ZSTD_versionString());
    mode_ace(argv[3], o, h_out, R, K);
    mode_zstd(o, h_out, R, 16384);
    mode_zstd(o, h_out, R, 65536);
    cudaFreeHost(h_out);
    if (g_kill) { printf("[hy] %s KILL: an output differs - no table\n", g_tag); return 5; }
    printf("[hy] %s: every output == original\n", g_tag); return 0;
}
