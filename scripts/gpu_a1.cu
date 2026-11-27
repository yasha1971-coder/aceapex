// gpu_a1.cu - GPU-A1, the deciding table of door A (one card): n random windows of W bytes (fixed seed) from a genome
// archive resident on the device, one batch, the output on the device. Three paths on the same windows:
//   ace   ACEAPEX GPU, the whole path in one call: aceapex_gpu_decompress_windows_async on the open-profile archive
//         (the selection of blocks and chunks, the entropy layer and the match layer on the device; src/aceapex_gpu.h)
//   zstd  nvCOMP batched zstd, 16 KiB chunks compressed by nvCOMP on the device; per batch: the chunks the windows need
//         (picked on the host), their pointers to the device, one batched decompress, a gather kernel into the windows
//   lz4   the same with nvCOMP batched LZ4
//   bgzf  htslib BGZF on the CPU (all hardware threads, one handle each, .gzi index), bgzf_useek + bgzf_read per window
//         into pinned memory, then one cudaMemcpy of the batch to the device
// Per path: size (archive + index), open time, batch latency (call to sync) median of R repeats in two blocks (A/A),
// windows/s and GB/s of output at the median, one-window latency (median of 200), and every window of the batch compared
// with the original (copied back outside the timer). Any window that differs: KILL, exit 5, no table.
// Build (CUDA 12, nvCOMP 6 C API - the GetTempSize calls take a stream since 6.0 -, htslib):
//   nvcc -std=c++17 -O3 -arch=sm_90 -Isrc -I<nvcomp>/include scripts/gpu_a1.cu src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp
//        -L<nvcomp>/lib -lnvcomp -lhts -lpthread -o gpu_a1
// Usage: gpu_a1 <archive.open.aet> <original> <original.bgz (with .gzi)> [n=10000] [W=16384] [R=20] [threads=all]
#include "aceapex_gpu.h"
#include <nvcomp/zstd.h>
#include <nvcomp/lz4.h>
#include <htslib/bgzf.h>
#include <cuda_runtime.h>
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
#include <sys/stat.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { printf("CUDA %s @%d: %s\n", #x, __LINE__, cudaGetErrorString(e_)); exit(2); } } while (0)
#define NV(x) do { nvcompStatus_t s_ = (x); if (s_ != nvcompSuccess) { printf("nvcomp %s @%d: status %d\n", #x, __LINE__, (int)s_); exit(3); } } while (0)
static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static std::vector<uint8_t> slurp(const char* p) {
    std::vector<uint8_t> v; FILE* f = fopen(p, "rb"); if (!f) { perror(p); exit(1); }
    fseek(f, 0, SEEK_END); v.resize((size_t)ftell(f)); fseek(f, 0, SEEK_SET);
    if (!v.empty() && fread(v.data(), 1, v.size(), f) != v.size()) { perror(p); exit(1); } fclose(f); return v; }
static double pct(std::vector<double> v, double p) { if (v.empty()) return 0; std::sort(v.begin(), v.end()); return v[std::min(v.size() - 1, (size_t)(p * v.size()))]; }
static const char* base(const char* p) { const char* s = strrchr(p, '/'); return s ? s + 1 : p; }
static uint64_t fsize(const std::string& p) { struct stat st; return stat(p.c_str(), &st) ? 0 : (uint64_t)st.st_size; }

struct Row { const char* path; uint64_t size; double open_ms, p50a, p50b, p99, one_us; bool ok; };
static std::vector<Row> rows;
static uint64_t g_orig = 0; static uint32_t g_n = 0, g_W = 0; static const char* g_name = "";
static void report(const Row& r) {
    const double p50 = std::min(r.p50a, r.p50b), aa = r.p50a > 0 ? 100.0 * (r.p50b - r.p50a) / r.p50a : 0;
    const double wps = p50 > 0 ? g_n / p50 : 0;
    printf("[a1] %-5s size %12llu B (ratio %.4f) open %8.1f ms | batch p50 %8.3f ms (A %.3f / B %.3f, A/A %+.1f %%) p99 %.3f ms | %10.0f windows/s %7.2f GB/s | one window %8.1f us | %s\n",
           r.path, (unsigned long long)r.size, r.size ? (double)g_orig / r.size : 0, r.open_ms, p50 * 1e3, r.p50a * 1e3, r.p50b * 1e3, aa, r.p99 * 1e3, wps, wps * g_W / 1e9, r.one_us,
           r.ok ? "all windows == original" : "DIFFERS");
    printf("A1ROW\t%s\t%s\t%u\t%u\t%llu\t%.4f\t%.1f\t%.3f\t%.3f\t%.1f\t%.3f\t%.0f\t%.2f\t%.1f\t%s\n", g_name, r.path, g_n, g_W, (unsigned long long)r.size,
           r.size ? (double)g_orig / r.size : 0, r.open_ms, r.p50a * 1e3, r.p50b * 1e3, aa, r.p99 * 1e3, wps, wps * g_W / 1e9, r.one_us, r.ok ? "ok" : "DIFFERS");
    rows.push_back(r);
}
static bool check_windows(const uint8_t* got, const std::vector<uint8_t>& o, const std::vector<uint64_t>& off, uint32_t n, uint32_t W) {
    for (uint32_t i = 0; i < n; i++) if (memcmp(got + (size_t)i * W, o.data() + off[i], W)) { printf("[a1] window %u (offset %llu) differs\n", i, (unsigned long long)off[i]); return false; }
    return true;
}
// two blocks of R timed repeats (A/A); fn() runs one batch to completion and returns false on an error
template <class F> static bool timed(F fn, int R, double& p50a, double& p50b, double& p99) {
    std::vector<double> a, b, all;
    for (int r = 0; r < 2; r++) if (!fn()) return false;                       // warm-up
    for (int blk = 0; blk < 2; blk++) for (int r = 0; r < R; r++) { const double t0 = now_s(); if (!fn()) return false; const double t = now_s() - t0; (blk ? b : a).push_back(t); all.push_back(t); }
    p50a = pct(a, .5); p50b = pct(b, .5); p99 = pct(all, .99); return true;
}

// ------------------------------------------------------------------ (a) ACEAPEX GPU
static bool path_ace(const char* arc, const char* label, const std::vector<uint8_t>& o, const std::vector<uint64_t>& off, uint32_t n, uint32_t W, int R) {
    const std::vector<uint8_t> a = slurp(arc); cudaStream_t s; CK(cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking));
    const double t0 = now_s(); aceapex_gpu_plan* pl = aceapex_gpu_plan_create(a.data(), a.size(), 0);
    if (!pl) { printf("[a1] ace plan_create failed: %d\n", aceapex_gpu_last_error()); return false; }
    uint8_t* d_in; CK(cudaMalloc(&d_in, a.size())); CK(cudaMemcpy(d_in, a.data(), a.size(), cudaMemcpyHostToDevice)); const double open_ms = (now_s() - t0) * 1e3;
    uint64_t* d_off; uint8_t *d_out, *d_tmp, *d_tmp1; int* d_st; const size_t tb = aceapex_gpu_windows_temp_bytes(pl, n, W), tb1 = aceapex_gpu_windows_temp_bytes(pl, 1, W);
    CK(cudaMalloc(&d_off, (size_t)n * 8)); CK(cudaMemcpy(d_off, off.data(), (size_t)n * 8, cudaMemcpyHostToDevice));
    CK(cudaMalloc(&d_out, (size_t)n * W)); CK(cudaMalloc(&d_tmp, tb)); CK(cudaMalloc(&d_tmp1, tb1)); CK(cudaMalloc(&d_st, 4));
    auto batch = [&] { if (aceapex_gpu_decompress_windows_async(pl, d_in, d_off, n, W, d_out, d_tmp, d_st, s)) return false; return cudaStreamSynchronize(s) == cudaSuccess; };
    Row r{label, (uint64_t)a.size(), open_ms, 0, 0, 0, 0, false};
    if (!timed(batch, R, r.p50a, r.p50b, r.p99)) { printf("[a1] ace batch failed\n"); return false; }
    int st = -1; CK(cudaMemcpy(&st, d_st, 4, cudaMemcpyDeviceToHost));
    std::vector<uint8_t> h((size_t)n * W); CK(cudaMemcpy(h.data(), d_out, h.size(), cudaMemcpyDeviceToHost));
    r.ok = st == 0 && check_windows(h.data(), o, off, n, W);
    std::mt19937_64 g(777); std::vector<double> one; uint64_t* d_o1; CK(cudaMalloc(&d_o1, 8));
    for (int k = 0; k < 200; k++) { const uint64_t x = g() % (g_orig - W + 1); CK(cudaMemcpy(d_o1, &x, 8, cudaMemcpyHostToDevice)); const double t0b = now_s();
        if (aceapex_gpu_decompress_windows_async(pl, d_in, d_o1, 1, W, d_out, d_tmp1, d_st, s)) { r.ok = false; break; } CK(cudaStreamSynchronize(s)); one.push_back(now_s() - t0b);
        CK(cudaMemcpy(h.data(), d_out, W, cudaMemcpyDeviceToHost)); CK(cudaMemcpy(&st, d_st, 4, cudaMemcpyDeviceToHost)); if (st != 0 || !check_windows(h.data(), o, {x}, 1, W)) r.ok = false; }   // every single window checked (GPU-A1 small block)
    r.one_us = pct(one, .5) * 1e6; report(r);
    cudaFree(d_in); cudaFree(d_off); cudaFree(d_out); cudaFree(d_tmp); cudaFree(d_tmp1); cudaFree(d_st); cudaFree(d_o1); aceapex_gpu_plan_destroy(pl); cudaStreamDestroy(s);
    return r.ok;
}

// ------------------------------------------------------------------ (b) nvCOMP batched zstd / LZ4, 16 KiB chunks
__global__ void k_gather(const uint8_t* dec, const uint32_t* slot, const uint64_t* off, uint32_t W, uint32_t C, uint8_t* out) {
    const uint32_t i = blockIdx.x; const uint64_t x = off[i]; const uint32_t s0 = slot[2 * i], s1 = slot[2 * i + 1];
    const uint32_t in0 = (uint32_t)(x % C);
    for (uint32_t k = threadIdx.x; k < W; k += blockDim.x) {
        const uint32_t p = in0 + k; out[(size_t)i * W + k] = p < C ? dec[(size_t)s0 * C + p] : dec[(size_t)s1 * C + (p - C)];
    }
}
enum Algo { ZSTD, LZ4 };
static bool path_nvcomp(Algo al, const std::vector<uint8_t>& o, const std::vector<uint64_t>& off, uint32_t n, uint32_t W, int R) {
    const size_t C = W, N = (g_orig + C - 1) / C; cudaStream_t s; CK(cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking));
    // compression on the device (setup, untimed): every chunk of the original
    uint8_t* d_orig; CK(cudaMalloc(&d_orig, g_orig)); CK(cudaMemcpy(d_orig, o.data(), g_orig, cudaMemcpyHostToDevice));
    std::vector<void*> hp(N); std::vector<size_t> hs(N);
    for (size_t i = 0; i < N; i++) { hp[i] = d_orig + i * C; hs[i] = std::min(C, (size_t)(g_orig - i * C)); }
    size_t maxc = 0, ctemp = 0;
    if (al == ZSTD) { NV(nvcompBatchedZstdCompressGetMaxOutputChunkSize(C, nvcompBatchedZstdCompressDefaultOpts, &maxc));
                      NV(nvcompBatchedZstdCompressGetTempSize(N, C, nvcompBatchedZstdCompressDefaultOpts, &ctemp, g_orig, s)); }
    else            { NV(nvcompBatchedLZ4CompressGetMaxOutputChunkSize(C, nvcompBatchedLZ4CompressDefaultOpts, &maxc));
                      NV(nvcompBatchedLZ4CompressGetTempSize(N, C, nvcompBatchedLZ4CompressDefaultOpts, &ctemp, g_orig, s)); }
    void **d_up, **d_cp; size_t *d_us, *d_cs; uint8_t *d_cbuf, *d_ctmp; nvcompStatus_t* d_cst;
    CK(cudaMalloc(&d_up, N * 8)); CK(cudaMalloc(&d_us, N * 8)); CK(cudaMalloc(&d_cp, N * 8)); CK(cudaMalloc(&d_cs, N * 8)); CK(cudaMalloc(&d_cst, N * sizeof(nvcompStatus_t)));
    CK(cudaMalloc(&d_cbuf, N * maxc)); CK(cudaMalloc(&d_ctmp, ctemp ? ctemp : 1));
    std::vector<void*> hcp(N); for (size_t i = 0; i < N; i++) hcp[i] = d_cbuf + i * maxc;
    CK(cudaMemcpy(d_up, hp.data(), N * 8, cudaMemcpyHostToDevice)); CK(cudaMemcpy(d_us, hs.data(), N * 8, cudaMemcpyHostToDevice)); CK(cudaMemcpy(d_cp, hcp.data(), N * 8, cudaMemcpyHostToDevice));
    if (al == ZSTD) NV(nvcompBatchedZstdCompressAsync((const void* const*)d_up, d_us, C, N, d_ctmp, ctemp, d_cp, d_cs, nvcompBatchedZstdCompressDefaultOpts, d_cst, s));
    else            NV(nvcompBatchedLZ4CompressAsync((const void* const*)d_up, d_us, C, N, d_ctmp, ctemp, d_cp, d_cs, nvcompBatchedLZ4CompressDefaultOpts, d_cst, s));
    CK(cudaStreamSynchronize(s));
    std::vector<size_t> cs(N); CK(cudaMemcpy(cs.data(), d_cs, N * 8, cudaMemcpyDeviceToHost));
    // the "archive": the compressed chunks back to back + a u64 offset table, kept on the host as a file would be
    std::vector<uint64_t> coff(N + 1, 0); for (size_t i = 0; i < N; i++) coff[i + 1] = coff[i] + cs[i];
    std::vector<uint8_t> arch(coff[N]); for (size_t i = 0; i < N; i++) CK(cudaMemcpy(arch.data() + coff[i], hcp[i], cs[i], cudaMemcpyDeviceToHost));
    cudaFree(d_orig); cudaFree(d_up); cudaFree(d_us); cudaFree(d_cp); cudaFree(d_cs); cudaFree(d_cst); cudaFree(d_cbuf); cudaFree(d_ctmp);
    Row r{al == ZSTD ? "zstd" : "lz4", coff[N] + 8 * (N + 1), 0, 0, 0, 0, 0, false};
    // open: the archive and its table to the device
    const double t0 = now_s(); uint8_t* d_arch; CK(cudaMalloc(&d_arch, arch.size())); CK(cudaMemcpy(d_arch, arch.data(), arch.size(), cudaMemcpyHostToDevice)); r.open_ms = (now_s() - t0) * 1e3;
    // batch buffers: at most 2 chunks per window
    const size_t MAXJ = std::min(N, (size_t)2 * n);
    size_t dtemp = 0;
    if (al == ZSTD) NV(nvcompBatchedZstdDecompressGetTempSize(MAXJ, C, nvcompBatchedZstdDecompressDefaultOpts, &dtemp, MAXJ * C, s));
    else            NV(nvcompBatchedLZ4DecompressGetTempSize(MAXJ, C, nvcompBatchedLZ4DecompressDefaultOpts, &dtemp, MAXJ * C, s));
    uint8_t *d_dec, *d_dtmp, *d_out; void **d_jp, **d_jo; size_t *d_jcs, *d_jos, *d_jact; nvcompStatus_t* d_jst; uint32_t* d_slot; uint64_t* d_off;
    CK(cudaMalloc(&d_dec, MAXJ * C)); CK(cudaMalloc(&d_dtmp, dtemp ? dtemp : 1)); CK(cudaMalloc(&d_out, (size_t)n * W));
    CK(cudaMalloc(&d_jp, MAXJ * 8)); CK(cudaMalloc(&d_jo, MAXJ * 8)); CK(cudaMalloc(&d_jcs, MAXJ * 8)); CK(cudaMalloc(&d_jos, MAXJ * 8)); CK(cudaMalloc(&d_jact, MAXJ * 8));
    CK(cudaMalloc(&d_jst, MAXJ * sizeof(nvcompStatus_t))); CK(cudaMalloc(&d_slot, (size_t)n * 8)); CK(cudaMalloc(&d_off, (size_t)n * 8));
    void **h_jp, **h_jo; size_t *h_jcs, *h_jos; uint32_t* h_slot;    // pinned staging of the per-batch tables
    CK(cudaHostAlloc(&h_jp, MAXJ * 8, 0)); CK(cudaHostAlloc(&h_jo, MAXJ * 8, 0)); CK(cudaHostAlloc(&h_jcs, MAXJ * 8, 0)); CK(cudaHostAlloc(&h_jos, MAXJ * 8, 0)); CK(cudaHostAlloc(&h_slot, (size_t)n * 8, 0));
    std::vector<uint32_t> stamp(N, 0), slotof(N, 0); uint32_t epoch = 0;
    // one batch: pick the chunks on the host, tables to the device, one batched decompress, gather the windows
    auto batch = [&](const uint64_t* hoff, uint32_t nn) {
        epoch++; size_t J = 0;
        for (uint32_t i = 0; i < nn; i++) { const uint64_t c0 = hoff[i] / C, c1 = (hoff[i] + W - 1) / C;
            for (uint64_t c = c0; c <= c1; c++) { if (stamp[c] != epoch) { stamp[c] = epoch; slotof[c] = (uint32_t)J;
                    h_jp[J] = d_arch + coff[c]; h_jcs[J] = cs[c]; h_jo[J] = d_dec + J * C; h_jos[J] = std::min(C, (size_t)(g_orig - c * C)); J++; } }
            h_slot[2 * i] = slotof[c0]; h_slot[2 * i + 1] = slotof[c1]; }
        if (cudaMemcpyAsync(d_jp, h_jp, J * 8, cudaMemcpyHostToDevice, s) || cudaMemcpyAsync(d_jo, h_jo, J * 8, cudaMemcpyHostToDevice, s) ||
            cudaMemcpyAsync(d_jcs, h_jcs, J * 8, cudaMemcpyHostToDevice, s) || cudaMemcpyAsync(d_jos, h_jos, J * 8, cudaMemcpyHostToDevice, s) ||
            cudaMemcpyAsync(d_slot, h_slot, (size_t)nn * 8, cudaMemcpyHostToDevice, s)) return false;
        nvcompStatus_t st = al == ZSTD
            ? nvcompBatchedZstdDecompressAsync((const void* const*)d_jp, d_jcs, d_jos, d_jact, J, d_dtmp, dtemp, (void* const*)d_jo, nvcompBatchedZstdDecompressDefaultOpts, d_jst, s)
            : nvcompBatchedLZ4DecompressAsync((const void* const*)d_jp, d_jcs, d_jos, d_jact, J, d_dtmp, dtemp, (void* const*)d_jo, nvcompBatchedLZ4DecompressDefaultOpts, d_jst, s);
        if (st != nvcompSuccess) return false;
        k_gather<<<nn, 256, 0, s>>>(d_dec, d_slot, d_off, W, (uint32_t)C, d_out);
        return cudaStreamSynchronize(s) == cudaSuccess; };
    CK(cudaMemcpy(d_off, off.data(), (size_t)n * 8, cudaMemcpyHostToDevice));
    if (!timed([&] { return batch(off.data(), n); }, R, r.p50a, r.p50b, r.p99)) { printf("[a1] %s batch failed\n", r.path); return false; }
    std::vector<nvcompStatus_t> jst(MAXJ); CK(cudaMemcpy(jst.data(), d_jst, MAXJ * sizeof(nvcompStatus_t), cudaMemcpyDeviceToHost));
    bool stok = true; { size_t J = 0; epoch++; for (uint32_t i = 0; i < n; i++) for (uint64_t c = off[i] / C; c <= (off[i] + W - 1) / C; c++) if (stamp[c] != epoch) { stamp[c] = epoch; J++; }
        for (size_t j = 0; j < J; j++) if (jst[j] != nvcompSuccess) { stok = false; break; } }
    std::vector<uint8_t> h((size_t)n * W); CK(cudaMemcpy(h.data(), d_out, h.size(), cudaMemcpyDeviceToHost));
    r.ok = stok && check_windows(h.data(), o, off, n, W);
    std::mt19937_64 g(777); std::vector<double> one;
    for (int k = 0; k < 200; k++) { uint64_t x = g() % (g_orig - W + 1); CK(cudaMemcpy(d_off, &x, 8, cudaMemcpyHostToDevice)); const double t0b = now_s(); if (!batch(&x, 1)) { r.ok = false; break; } one.push_back(now_s() - t0b);
        CK(cudaMemcpy(h.data(), d_out, W, cudaMemcpyDeviceToHost)); if (!check_windows(h.data(), o, {x}, 1, W)) r.ok = false; }   // every single window checked
    r.one_us = pct(one, .5) * 1e6; report(r);
    cudaFree(d_arch); cudaFree(d_dec); cudaFree(d_dtmp); cudaFree(d_out); cudaFree(d_jp); cudaFree(d_jo); cudaFree(d_jcs); cudaFree(d_jos); cudaFree(d_jact); cudaFree(d_jst); cudaFree(d_slot); cudaFree(d_off);
    cudaFreeHost(h_jp); cudaFreeHost(h_jo); cudaFreeHost(h_jcs); cudaFreeHost(h_jos); cudaFreeHost(h_slot); cudaStreamDestroy(s);
    return r.ok;
}

// ------------------------------------------------------------------ (c) bgzip / htslib on the CPU + copy to the device
static bool path_bgzf(const char* bgz, const std::vector<uint8_t>& o, const std::vector<uint64_t>& off, uint32_t n, uint32_t W, int R, int T) {
    const double t0 = now_s(); std::vector<BGZF*> fp(T);
    for (int t = 0; t < T; t++) { fp[t] = bgzf_open(bgz, "r"); if (!fp[t] || bgzf_index_load(fp[t], bgz, ".gzi")) { printf("[a1] bgzf open / .gzi failed\n"); return false; } }
    Row r{"bgzf", fsize(bgz) + fsize(std::string(bgz) + ".gzi"), (now_s() - t0) * 1e3, 0, 0, 0, 0, false};
    uint8_t *h_buf, *d_buf; CK(cudaHostAlloc(&h_buf, (size_t)n * W, 0)); CK(cudaMalloc(&d_buf, (size_t)n * W));
    auto batch = [&] { std::atomic<uint32_t> nx{0}; std::atomic<int> bad{0}; std::vector<std::thread> th;
        for (int t = 0; t < T; t++) th.emplace_back([&, t] { for (uint32_t i; (i = nx++) < n; ) {
            if (bgzf_useek(fp[t], (off_t)off[i], SEEK_SET) < 0 || bgzf_read(fp[t], h_buf + (size_t)i * W, W) != (ssize_t)W) bad = 1; } });
        for (auto& x : th) x.join();
        if (bad) return false;
        return cudaMemcpy(d_buf, h_buf, (size_t)n * W, cudaMemcpyHostToDevice) == cudaSuccess; };
    if (!timed(batch, R, r.p50a, r.p50b, r.p99)) { printf("[a1] bgzf batch failed\n"); return false; }
    r.ok = check_windows(h_buf, o, off, n, W);
    std::mt19937_64 g(777); std::vector<double> one;
    for (int k = 0; k < 200; k++) { const uint64_t x = g() % (g_orig - W + 1); const double t0b = now_s();
        if (bgzf_useek(fp[0], (off_t)x, SEEK_SET) < 0 || bgzf_read(fp[0], h_buf, W) != (ssize_t)W || cudaMemcpy(d_buf, h_buf, W, cudaMemcpyHostToDevice)) { r.ok = false; break; }
        one.push_back(now_s() - t0b); }
    r.one_us = pct(one, .5) * 1e6; report(r);
    for (auto* f : fp) bgzf_close(f); cudaFreeHost(h_buf); cudaFree(d_buf);
    return r.ok;
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc < 4) { fprintf(stderr, "usage: %s <archive.open.aet> <original> <original.bgz> [n] [W] [R] [threads]\n", argv[0]); return 1; }
    const std::vector<uint8_t> o = slurp(argv[2]); g_orig = o.size(); g_name = base(argv[2]);
    g_n = argc > 4 ? (uint32_t)atoi(argv[4]) : 10000; g_W = argc > 5 ? (uint32_t)atoi(argv[5]) : 16384;
    const int R = argc > 6 ? atoi(argv[6]) : 20, T = argc > 7 ? atoi(argv[7]) : (int)std::thread::hardware_concurrency();
    std::mt19937_64 g(20261127ull); std::vector<uint64_t> off(g_n); for (auto& x : off) x = g() % (g_orig - g_W + 1);
    cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, 0));
    printf("[a1] %s: %.3f GB original, %u windows x %u B (seed 20261127), %d repeats x 2 blocks, CPU threads %d, GPU %s, ace gpu api %u\n",
           g_name, g_orig / 1e9, g_n, g_W, R, T, p.name, aceapex_gpu_version());
    bool ok = true;   // argv[1]: one archive or a comma list of archive[=label] (GPU-A1 small block: 16 KiB / 64 KiB / 1 MiB in one process)
    { std::string L = argv[1]; size_t p0 = 0; while (p0 <= L.size()) { size_t p1 = L.find(',', p0); if (p1 == std::string::npos) p1 = L.size();
        std::string it = L.substr(p0, p1 - p0), lab = "ace"; const size_t e = it.find('='); if (e != std::string::npos) { lab = it.substr(e + 1); it = it.substr(0, e); }
        if (!it.empty()) ok = path_ace(it.c_str(), strdup(lab.c_str()), o, off, g_n, g_W, R) && ok; p0 = p1 + 1; } }
    ok = path_nvcomp(ZSTD, o, off, g_n, g_W, R) && ok;
    ok = path_nvcomp(LZ4, o, off, g_n, g_W, R) && ok;
    if (strcmp(argv[3], "-")) ok = path_bgzf(argv[3], o, off, g_n, g_W, R, T) && ok;   // "-": no BGZF path
    if (!ok) { printf("[a1] KILL: a window differs or a path failed - no table\n"); return 5; }
    printf("[a1] all paths: every window == original\n");
    return 0;
}
