// gpu_h100_tests.cu - four card tests for the H100 run (scripts/gpu_run.sh ONE): saturation, the PCIe pipeline, random
// access by coordinate, and corrupt archives on the open path. Library calls only (src/aceapex_gpu.h).
//
//   sat    <archive> [max_copies]          T-H1: K decodes of the same archive at once (one resident archive, a plan,
//                                          K streams each with its own temp and output: 25-50 GB of output on an
//                                          80 GB card), K = 1, 2, 4, ... up to what fits; aggregate GB/s per K, the
//                                          peak; every copy checked once with ACEAPEX_GPU_VERIFY_XXH3 (status 0).
//   pcie   <archive> <original> [slot_MB]  T-H2: the archive in pinned host memory goes to the device through a ring
//                                          of 4 slots of slot_MB (4 and 8 by default) as block batches whose archive
//                                          slice fits a slot; H2D of one slot overlaps the decode of another
//                                          (block-range plans). Against: H2D alone (pinned, whole archive and in
//                                          slot-sized copies) and the decode alone with the archive resident. Every
//                                          batch checked against the original in an untimed pass.
//   ra     <archive> <fasta> [n] [len] [samtools] [bgz]
//                                          T-H3: n (10 000) regions of len (5 000) bases at random coordinates
//                                          (contig by length, start uniform; offsets from the FASTA's line layout);
//                                          GPU: resident archive, pooled buffers, one region per call + D2H + sync,
//                                          direct launches and CUDA Graph capture (update or re-instantiate per
//                                          region); CPU: aceapex_decompress_region on one thread; samtools faidx on
//                                          the bgzip file per region (a process per call) and for all regions in one
//                                          call (-r). Latency p50 / p99, every result compared with the FASTA.
//                                          Writes regions.txt (chr:start-end, 1-based) next to the archive.
//   stress <archive.open> <original> [n]   T-H4: n (10 000) corrupt copies (bit flip, random bytes, zeroed run,
//                                          truncation, header/table hit, literal or token stream hit); each: plan
//                                          (refused?), decode with a 10 s watchdog (hang?), status, output against
//                                          the original (harmless / caught / silent), then the same with
//                                          ACEAPEX_GPU_VERIFY_XXH3 (silent must be 0).
// Last line of each: H1ROW / H2ROW / H3ROW / H4ROW (tab separated) for the SUMMARY.
// Build: nvcc -std=c++17 -O3 -arch=sm_90 -Isrc [-DACEAPEX_GPU_NVCOMP <nvcomp>] scripts/gpu_h100_tests.cu
//        src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp src/aceapex_api.cpp -lzstd -lpthread
#include "aceapex_gpu.h"
#include "aceapex.h"
#define XXH_INLINE_ALL
#include "xxhash.h"
#include <cuda_runtime.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
extern char** environ;
#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { printf("CUDA %s @%d: %s\n", #x, __LINE__, cudaGetErrorString(e_)); exit(2); } } while (0)
static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static std::vector<uint8_t> slurp(const char* p) { std::vector<uint8_t> v; FILE* f = fopen(p, "rb"); if (!f) { perror(p); exit(1); }
    fseek(f, 0, SEEK_END); v.resize((size_t)ftell(f)); fseek(f, 0, SEEK_SET); if (fread(v.data(), 1, v.size(), f) != v.size()) exit(1); fclose(f); return v; }
static double pct(std::vector<double> v, double p) { if (v.empty()) return 0; std::sort(v.begin(), v.end()); return v[std::min(v.size() - 1, (size_t)(p * v.size()))]; }
static const char* base(const char* p) { const char* s = strrchr(p, '/'); return s ? s + 1 : p; }
// wait for an event with a deadline; false = the deadline passed (a hang: the context is not usable any more)
static bool wait_ev(cudaEvent_t e, double sec) { const double t = now_s(); for (;;) { const cudaError_t r = cudaEventQuery(e);
    if (r == cudaSuccess) return true; if (r != cudaErrorNotReady) { printf("CUDA event: %s\n", cudaGetErrorString(r)); exit(2); }
    if (now_s() - t > sec) return false; usleep(50); } }

// ---------------------------------------------------------------- T-H1 saturation
static int t_sat(int argc, char** argv) {
    const std::vector<uint8_t> a = slurp(argv[2]); const int maxk = argc > 3 ? atoi(argv[3]) : 16;
    aceapex_gpu_plan* pl = aceapex_gpu_plan_create(a.data(), a.size(), 0); if (!pl) { printf("plan_create: %d\n", aceapex_gpu_last_error()); return 3; }
    const size_t out = aceapex_gpu_output_bytes(pl), tmp = aceapex_gpu_temp_bytes(pl);
    uint8_t* d_in; CK(cudaMalloc(&d_in, a.size())); CK(cudaMemcpy(d_in, a.data(), a.size(), cudaMemcpyHostToDevice));
    size_t fr, tot; CK(cudaMemGetInfo(&fr, &tot));
    int K = (int)std::min<size_t>((size_t)maxk, (size_t)((double)fr * 0.92 / (double)(out + tmp + 4096)));
    if (K < 1) { printf("[sat] one copy does not fit (%.1f GB free, %.1f GB per copy)\n", fr / 1e9, (out + tmp) / 1e9); return 4; }
    printf("[sat] %s: output %.2f GB + temp %.2f GB per copy; %.1f of %.1f GB free: up to %d copies at once\n", base(argv[2]), out / 1e9, tmp / 1e9, fr / 1e9, tot / 1e9, K);
    std::vector<uint8_t*> d_out(K), d_tmp(K); std::vector<int*> d_st(K); std::vector<cudaStream_t> s(K); std::vector<cudaEvent_t> e0(K), e1(K);
    for (int k = 0; k < K; k++) { CK(cudaMalloc(&d_out[k], out)); CK(cudaMalloc(&d_tmp[k], tmp)); CK(cudaMalloc(&d_st[k], 4));
        CK(cudaStreamCreateWithFlags(&s[k], cudaStreamNonBlocking)); CK(cudaEventCreate(&e0[k])); CK(cudaEventCreate(&e1[k])); }
    // check once: every copy with the on-device XXH3
    int bad = 0;
    for (int k = 0; k < K; k++) { if (aceapex_gpu_decompress_async(pl, d_in, d_out[k], d_tmp[k], d_st[k], ACEAPEX_GPU_VERIFY_XXH3, s[k])) bad++; }
    CK(cudaDeviceSynchronize()); for (int k = 0; k < K; k++) { int st = -1; CK(cudaMemcpy(&st, d_st[k], 4, cudaMemcpyDeviceToHost)); if (st) bad++; }
    double peak = 0; int peak_k = 0; std::string rows;
    for (int k = 1; k <= K; k = (k == K ? K + 1 : std::min(K, k * 2))) {
        std::vector<double> w;
        for (int rep = 0; rep < 3; rep++) {
            CK(cudaDeviceSynchronize()); const double t0 = now_s();
            for (int j = 0; j < k; j++) aceapex_gpu_decompress_async(pl, d_in, d_out[j], d_tmp[j], d_st[j], 0, s[j]);
            CK(cudaDeviceSynchronize()); w.push_back(now_s() - t0); }
        const double med = pct(w, 0.5), gbs = (double)out * k / med / 1e9;
        printf("[sat] %2d at once: %.3f s for %.1f GB -> %.1f GB/s\n", k, med, (double)out * k / 1e9, gbs);
        char b[64]; snprintf(b, sizeof b, "%s%d:%.1f", rows.empty() ? "" : ",", k, gbs); rows += b;
        if (gbs > peak) { peak = gbs; peak_k = k; }
    }
    printf("[sat] peak %.1f GB/s with %d decodes at once (%.1f GB of output); XXH3 check of %d copies: %s\n", peak, peak_k, (double)out * peak_k / 1e9, K, bad ? "FAILED" : "all status 0");
    printf("H1ROW\t%s\t%zu\t%d\t%.1f\t%d\t%s\t%s\n", base(argv[2]), out, K, peak, peak_k, rows.c_str(), bad ? "FAILED" : "ok");
    return bad ? 5 : 0;
}

// ---------------------------------------------------------------- T-H2 PCIe pipeline
static int t_pcie(int argc, char** argv) {
    const std::vector<uint8_t> av = slurp(argv[2]); const std::vector<uint8_t> orig = slurp(argv[3]);
    std::vector<int> slots_mb; if (argc > 4) slots_mb.push_back(atoi(argv[4])); else slots_mb = {4, 8};
    uint8_t* h_a; CK(cudaHostAlloc(&h_a, av.size(), cudaHostAllocDefault)); memcpy(h_a, av.data(), av.size());
    uint32_t nb, bs; uint64_t n; memcpy(&nb, h_a + 24, 4); memcpy(&bs, h_a + 20, 4); memcpy(&n, h_a + 12, 8);
    uint8_t* d_a; CK(cudaMalloc(&d_a, av.size()));
    cudaEvent_t x0, x1; CK(cudaEventCreate(&x0)); CK(cudaEventCreate(&x1)); float ms = 0;
    // H2D alone: whole archive, pinned
    std::vector<double> hw; for (int r = 0; r < 3; r++) { CK(cudaEventRecord(x0)); CK(cudaMemcpyAsync(d_a, h_a, av.size(), cudaMemcpyHostToDevice)); CK(cudaEventRecord(x1)); CK(cudaEventSynchronize(x1)); CK(cudaEventElapsedTime(&ms, x0, x1)); hw.push_back(ms / 1e3); }
    const double h2d = av.size() / pct(hw, 0.5) / 1e9;
    // decode alone, archive resident
    aceapex_gpu_plan* full = aceapex_gpu_plan_create(h_a, av.size(), 0); if (!full) { printf("plan_create: %d\n", aceapex_gpu_last_error()); return 3; }
    { uint8_t *o, *t; int* st; CK(cudaMalloc(&o, aceapex_gpu_output_bytes(full))); CK(cudaMalloc(&t, aceapex_gpu_temp_bytes(full))); CK(cudaMalloc(&st, 4));
      std::vector<double> dw; for (int r = 0; r < 4; r++) { CK(cudaEventRecord(x0)); aceapex_gpu_decompress_async(full, d_a, o, t, st, 0, 0); CK(cudaEventRecord(x1)); CK(cudaEventSynchronize(x1)); CK(cudaEventElapsedTime(&ms, x0, x1)); if (r) dw.push_back(ms / 1e3); }
      const double dec = pct(dw, 0.5);
      printf("[pcie] %s: archive %.1f MB -> %.2f GB; H2D pinned whole archive %.1f GB/s (%.1f ms); decode resident %.2f ms = %.1f GB/s of output, %.1f GB/s of archive\n",
             base(argv[2]), av.size() / 1e6, n / 1e9, h2d, av.size() / h2d / 1e6, dec * 1e3, n / dec / 1e9, av.size() / dec / 1e9);
      printf("[pcie] the decode eats archive bytes %.1fx faster than the bus brings them\n", av.size() / dec / 1e9 / h2d);
      CK(cudaFree(o)); CK(cudaFree(t)); CK(cudaFree(st)); }
    aceapex_gpu_plan_destroy(full); CK(cudaFree(d_a));
    std::string row;
    for (int smb : slots_mb) {
        const size_t SLOT = (size_t)smb << 20; const int NS = 4;
        // batches: as many blocks as keep the archive slice within a slot (grown block by block with the plan's window)
        std::vector<aceapex_gpu_plan*> pl; std::vector<uint64_t> lo, hi;
        { uint32_t b0 = 0; uint32_t step = std::max<uint32_t>(1, (uint32_t)((double)SLOT / ((double)av.size() / nb) * 0.9));
          while (b0 < nb) { uint32_t b1 = std::min(nb, b0 + step); aceapex_gpu_plan* p = nullptr; uint64_t l = 0, h = 0;
              for (;;) { p = aceapex_gpu_plan_create_blocks(h_a, av.size(), b0, b1, 0); if (!p) { printf("plan_create_blocks: %d\n", aceapex_gpu_last_error()); return 3; }
                  aceapex_gpu_plan_input_window(p, &l, &h); if (h - l <= SLOT || b1 == b0 + 1) break;
                  aceapex_gpu_plan_destroy(p); b1 = b0 + std::max<uint32_t>(1, (b1 - b0) * 3 / 4); }
              pl.push_back(p); lo.push_back(l); hi.push_back(h); b0 = b1; } }
        size_t mo = 0, mt = 0; for (auto p : pl) { mo = std::max(mo, aceapex_gpu_output_bytes(p)); mt = std::max(mt, aceapex_gpu_temp_bytes(p)); }
        uint8_t *d_in[NS], *d_o[NS], *d_t[NS], *h_o[NS]; int* d_s[NS]; cudaStream_t s[NS]; cudaEvent_t done[NS];
        for (int k = 0; k < NS; k++) { CK(cudaMalloc(&d_in[k], SLOT + 256)); CK(cudaMalloc(&d_o[k], mo + 256)); CK(cudaMalloc(&d_t[k], mt + 256)); CK(cudaMalloc(&d_s[k], 4));
            CK(cudaHostAlloc(&h_o[k], mo + 256, cudaHostAllocDefault)); CK(cudaStreamCreateWithFlags(&s[k], cudaStreamNonBlocking)); CK(cudaEventCreate(&done[k])); }
        // H2D alone in slot-sized copies (the same pieces the pipeline sends)
        std::vector<double> sw; for (int r = 0; r < 3; r++) { CK(cudaDeviceSynchronize()); const double t0 = now_s();
            for (size_t i = 0; i < pl.size(); i++) CK(cudaMemcpyAsync(d_in[i % NS], h_a + lo[i], hi[i] - lo[i], cudaMemcpyHostToDevice, s[i % NS]));
            CK(cudaDeviceSynchronize()); sw.push_back(now_s() - t0); }
        const double h2d_slots = av.size() / pct(sw, 0.5) / 1e9;
        // pipeline: H2D -> decode per slot, slots in turn (result stays on the device), then with D2H too
        auto run = [&](bool d2h) { std::vector<double> w; for (int r = 0; r < 3; r++) { CK(cudaDeviceSynchronize()); const double t0 = now_s();
                for (size_t i = 0; i < pl.size(); i++) { const int k = (int)(i % NS);
                    CK(cudaMemcpyAsync(d_in[k], h_a + lo[i], hi[i] - lo[i], cudaMemcpyHostToDevice, s[k]));
                    aceapex_gpu_decompress_async(pl[i], d_in[k], d_o[k], d_t[k], d_s[k], 0, s[k]);
                    if (d2h) CK(cudaMemcpyAsync(h_o[k], d_o[k], aceapex_gpu_output_bytes(pl[i]), cudaMemcpyDeviceToHost, s[k])); }
                CK(cudaDeviceSynchronize()); w.push_back(now_s() - t0); } return pct(w, 0.5); };
        const double tp = run(false), tpd = run(true);
        // check (untimed): every batch back and compared
        size_t bad = 0; uint64_t pos = 0;
        for (size_t i = 0; i < pl.size(); i++) { const int k = 0; const size_t len = aceapex_gpu_output_bytes(pl[i]);
            CK(cudaMemcpy(d_in[k], h_a + lo[i], hi[i] - lo[i], cudaMemcpyHostToDevice)); aceapex_gpu_decompress_async(pl[i], d_in[k], d_o[k], d_t[k], d_s[k], 0, s[k]);
            CK(cudaStreamSynchronize(s[k])); int st = -1; CK(cudaMemcpy(&st, d_s[k], 4, cudaMemcpyDeviceToHost)); CK(cudaMemcpy(h_o[k], d_o[k], len, cudaMemcpyDeviceToHost));
            if (st || pos + len > orig.size() || memcmp(h_o[k], orig.data() + pos, len)) bad++; pos += len; }
        if (pos != orig.size()) bad++;
        printf("[pcie] ring %d x %d MB: %zu batches (<= %.1f MB of archive, %.1f MB of output each); H2D in these pieces %.1f GB/s; "
               "H2D -> decode %.3f s = %.1f GB/s of output (archive at %.1f GB/s = %.0f %% of the bus); + D2H %.3f s = %.1f GB/s; batches %s\n",
               NS, smb, pl.size(), SLOT / 1e6, mo / 1e6, h2d_slots, tp, n / tp / 1e9, av.size() / tp / 1e9, 100.0 * av.size() / tp / 1e9 / h2d, tpd, n / tpd / 1e9, bad ? "DIFFER" : "== original");
        char b[160]; snprintf(b, sizeof b, "%s%dMB:%.1f/%.1f/%.0f%%", row.empty() ? "" : ",", smb, n / tp / 1e9, n / tpd / 1e9, 100.0 * av.size() / tp / 1e9 / h2d); row += b;
        for (int k = 0; k < NS; k++) { cudaFree(d_in[k]); cudaFree(d_o[k]); cudaFree(d_t[k]); cudaFree(d_s[k]); cudaFreeHost(h_o[k]); cudaStreamDestroy(s[k]); }
        for (auto p : pl) aceapex_gpu_plan_destroy(p);
        if (bad) { printf("H2ROW\t%s\t%.1f\t%s\tFAILED\n", base(argv[2]), h2d, row.c_str()); return 5; }
    }
    printf("H2ROW\t%s\t%.1f\t%s\tok\n", base(argv[2]), h2d, row.c_str());   // bus GB/s, per slot size: out GB/s / with D2H / bus share
    return 0;
}

// ---------------------------------------------------------------- T-H3 random access
struct Rec { std::string name; uint64_t seq_len, off, lb, lw; };          // .fai fields: length, offset, line bases, line width
static std::vector<Rec> fai(const std::vector<uint8_t>& f) {
    std::vector<Rec> r; size_t i = 0; const size_t n = f.size();
    while (i < n) { if (f[i] != '>') { i++; continue; }
        size_t e = i; while (e < n && f[e] != '\n') e++;
        std::string nm((const char*)&f[i + 1], e - i - 1); nm = nm.substr(0, nm.find_first_of(" \t"));
        Rec q{nm, 0, e + 1, 0, 0}; size_t p = e + 1;
        while (p < n && f[p] != '>') { size_t le = p; while (le < n && f[le] != '\n') le++; const uint64_t L = le - p;
            if (!q.lb) { q.lb = L; q.lw = L + 1; } q.seq_len += L; p = le + 1; }
        r.push_back(q); i = p; }
    return r;
}
static uint64_t boff(const Rec& r, uint64_t pos) { return r.off + pos / r.lb * r.lw + pos % r.lb; }
static std::string bases(const uint8_t* p, size_t n) { std::string s; s.reserve(n); for (size_t i = 0; i < n; i++) if (p[i] != '\n' && p[i] != '\r') s += (char)p[i]; return s; }
static double run_cmd(const std::vector<std::string>& args, std::string& out) {   // posix_spawn, stdout captured; seconds
    int fd[2]; if (pipe(fd)) return -1; posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fd[1], 1); posix_spawn_file_actions_addclose(&fa, fd[0]);
    std::vector<char*> av; for (auto& a : args) av.push_back((char*)a.c_str()); av.push_back(nullptr);
    const double t0 = now_s(); pid_t pid; if (posix_spawnp(&pid, av[0], &fa, nullptr, av.data(), environ)) { close(fd[0]); close(fd[1]); return -1; }
    close(fd[1]); out.clear(); char b[65536]; ssize_t k; while ((k = read(fd[0], b, sizeof b)) > 0) out.append(b, (size_t)k); close(fd[0]);
    int st; waitpid(pid, &st, 0); posix_spawn_file_actions_destroy(&fa); return now_s() - t0;
}
static int t_ra(int argc, char** argv) {
    const std::vector<uint8_t> a = slurp(argv[2]), f = slurp(argv[3]);
    const int N = argc > 4 ? atoi(argv[4]) : 10000; const uint64_t LEN = argc > 5 ? strtoull(argv[5], 0, 10) : 5000;
    const char* sam = argc > 6 ? argv[6] : nullptr; const char* bgz = argc > 7 ? argv[7] : nullptr;
    const std::vector<Rec> R = fai(f); uint64_t tot = 0; for (auto& r : R) if (r.seq_len > LEN) tot += r.seq_len - LEN;
    std::mt19937_64 g(20261002); struct Q { size_t rec; uint64_t s, lo, len; }; std::vector<Q> q;
    for (int i = 0; i < N; i++) { uint64_t x = g() % tot; size_t k = 0; for (; k < R.size(); k++) { if (R[k].seq_len <= LEN) continue; const uint64_t span = R[k].seq_len - LEN; if (x < span) break; x -= span; }
        const uint64_t lo = boff(R[k], x), hi = boff(R[k], x + LEN - 1) + 1; q.push_back({k, x, lo, hi - lo}); }
    { std::string rp = std::string(argv[2]) + ".regions.txt"; FILE* o = fopen(rp.c_str(), "w");
      for (auto& x : q) fprintf(o, "%s:%llu-%llu\n", R[x.rec].name.c_str(), (unsigned long long)x.s + 1, (unsigned long long)(x.s + LEN)); fclose(o); }
    uint64_t maxlen = 0; for (auto& x : q) maxlen = std::max(maxlen, x.len);
    printf("[ra] %s: %d regions of %llu bases over %zu records (byte length <= %llu)\n", base(argv[3]), N, (unsigned long long)LEN, R.size(), (unsigned long long)maxlen);
    const bool gpu = strcmp(argv[1], "ra-cpu") != 0;                      // ra-cpu: the CPU and samtools rows only (a host without a card)
    std::vector<double> tg, tgg, tc, ts; int bad_g = 0, bad_gg = 0, bad_c = 0, bad_s = 0, graph_upd = 0, graph_new = 0, graph_fail = 0;
    auto check = [&](const Q& x, const uint8_t* p) { return bases(p, x.len) == bases(f.data() + x.lo, x.len); };
    if (gpu) {
    // GPU: resident archive, pooled buffers
    aceapex_gpu_plan* pl = aceapex_gpu_plan_create(a.data(), a.size(), 0); if (!pl) { printf("plan_create: %d\n", aceapex_gpu_last_error()); return 3; }
    uint8_t *d_in, *d_out, *d_tmp, *h_out; int *d_st, *h_st; cudaStream_t s; CK(cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking));
    CK(cudaMalloc(&d_in, a.size())); CK(cudaMemcpy(d_in, a.data(), a.size(), cudaMemcpyHostToDevice));
    const size_t rt = aceapex_gpu_range_temp_bytes(pl, maxlen); CK(cudaMalloc(&d_out, maxlen + 256)); CK(cudaMalloc(&d_tmp, rt)); CK(cudaMalloc(&d_st, 4));
    CK(cudaHostAlloc(&h_out, maxlen + 256, cudaHostAllocDefault)); CK(cudaHostAlloc(&h_st, 4, cudaHostAllocDefault));
    for (int i = 0; i < std::min(N, 200); i++) { aceapex_gpu_decompress_range_async(pl, d_in, q[i].lo, q[i].len, d_out, d_tmp, d_st, s); } CK(cudaStreamSynchronize(s));   // warm-up
    for (int i = 0; i < N; i++) { const Q& x = q[i]; const double t0 = now_s();
        const int r = aceapex_gpu_decompress_range_async(pl, d_in, x.lo, x.len, d_out, d_tmp, d_st, s);
        CK(cudaMemcpyAsync(h_out, d_out, x.len, cudaMemcpyDeviceToHost, s)); CK(cudaMemcpyAsync(h_st, d_st, 4, cudaMemcpyDeviceToHost, s)); CK(cudaStreamSynchronize(s));
        tg.push_back(now_s() - t0); if (r || *h_st || !check(x, h_out)) bad_g++; }
    // CUDA Graph: the range call captured; the executable graph updated in place when the topology allows, else rebuilt
    cudaGraphExec_t ex = nullptr;
    for (int i = 0; i < N; i++) { const Q& x = q[i]; const double t0 = now_s(); cudaGraph_t gr;
        if (cudaStreamBeginCapture(s, cudaStreamCaptureModeThreadLocal) != cudaSuccess) { graph_fail++; break; }
        const int r = aceapex_gpu_decompress_range_async(pl, d_in, x.lo, x.len, d_out, d_tmp, d_st, s);
        cudaMemcpyAsync(h_out, d_out, x.len, cudaMemcpyDeviceToHost, s); cudaMemcpyAsync(h_st, d_st, 4, cudaMemcpyDeviceToHost, s);
        if (cudaStreamEndCapture(s, &gr) != cudaSuccess || r) { graph_fail++; cudaGetLastError(); break; }
        bool upd = false;
        if (ex) { cudaGraphExecUpdateResultInfo info; upd = cudaGraphExecUpdate(ex, gr, &info) == cudaSuccess; if (!upd) { cudaGetLastError(); cudaGraphExecDestroy(ex); ex = nullptr; } }
        if (!ex) { if (cudaGraphInstantiate(&ex, gr, 0) != cudaSuccess) { graph_fail++; cudaGraphDestroy(gr); break; } graph_new++; } else graph_upd++;
        CK(cudaGraphLaunch(ex, s)); CK(cudaStreamSynchronize(s)); cudaGraphDestroy(gr);
        tgg.push_back(now_s() - t0); if (*h_st || !check(x, h_out)) bad_gg++; }
    if (ex) cudaGraphExecDestroy(ex);
    }
    // CPU: the region call, one thread
    std::vector<uint8_t> cb(maxlen + 64);
    for (int i = 0; i < N; i++) { const Q& x = q[i]; const double t0 = now_s();
        const int64_t r = aceapex_decompress_region(a.data(), a.size(), cb.data(), cb.size(), x.lo, x.len); tc.push_back(now_s() - t0);
        if (r != (int64_t)x.len || !check(x, cb.data())) bad_c++; }
    // samtools faidx on the bgzip file: a process per region, and every region in one call (-r)
    double sam_all = -1; int sam_n = 0;
    if (sam && bgz) {
        for (int i = 0; i < N; i++) { const Q& x = q[i]; char reg[256]; snprintf(reg, sizeof reg, "%s:%llu-%llu", R[x.rec].name.c_str(), (unsigned long long)x.s + 1, (unsigned long long)(x.s + LEN));
            std::string out; const double t = run_cmd({sam, "faidx", bgz, reg}, out); if (t < 0) break; ts.push_back(t); sam_n++;
            const size_t nl = out.find('\n'); std::string b = nl == std::string::npos ? "" : bases((const uint8_t*)out.data() + nl + 1, out.size() - nl - 1);
            if (b != bases(f.data() + x.lo, x.len)) bad_s++; }
        std::string out; sam_all = run_cmd({sam, "faidx", bgz, "-r", std::string(argv[2]) + ".regions.txt"}, out);
    }
    auto line = [&](const char* nm, const std::vector<double>& v, int bad) { if (v.empty()) { printf("[ra] %-38s -\n", nm); return; }
        double m = 0; for (double x : v) m += x; printf("[ra] %-38s p50 %8.1f us  p99 %8.1f us  mean %8.1f us  %s\n", nm, pct(v, 0.5) * 1e6, pct(v, 0.99) * 1e6, m / v.size() * 1e6, bad ? "DIFFERS" : "== FASTA"); };
    line("GPU range call + D2H + sync", tg, bad_g);
    char gl[96]; snprintf(gl, sizeof gl, "GPU CUDA Graph (%d updated, %d built)", graph_upd, graph_new); line(gl, tgg, bad_gg + graph_fail);
    line("CPU aceapex_decompress_region, 1 thread", tc, bad_c);
    line("samtools faidx bgzip, process per region", ts, bad_s);
    if (sam_all >= 0) printf("[ra] samtools faidx bgzip, %d regions in one call (-r): %.2f s = %.1f us per region\n", N, sam_all, sam_all / N * 1e6);
    const bool ok = !bad_g && !bad_gg && !graph_fail && !bad_c && !bad_s && (!gpu || (!tg.empty() && !tgg.empty()));
    printf("H3ROW\t%s\t%d\t%llu\t%.1f/%.1f\t%.1f/%.1f\t%.1f/%.1f\t%.1f/%.1f\t%.1f\t%s\n", base(argv[2]), N, (unsigned long long)LEN, pct(tg, .5) * 1e6, pct(tg, .99) * 1e6,
           pct(tgg, .5) * 1e6, pct(tgg, .99) * 1e6, pct(tc, .5) * 1e6, pct(tc, .99) * 1e6, pct(ts, .5) * 1e6, pct(ts, .99) * 1e6, sam_all >= 0 ? sam_all / N * 1e6 : -1.0, ok ? "ok" : "FAILED");
    return ok ? 0 : 5;
}

// ---------------------------------------------------------------- T-H4 corrupt archives
static int t_stress(int argc, char** argv) {
    const std::vector<uint8_t> a0 = slurp(argv[2]), orig = slurp(argv[3]); const int N = argc > 4 ? atoi(argv[4]) : 10000;
    uint32_t nb; memcpy(&nb, a0.data() + 24, 4); uint64_t z[4]; memcpy(z, a0.data() + 36, 32);
    const uint64_t tab_end = 68 + 64ull * nb, lit_lo = tab_end, lit_hi = lit_lo + z[0], tok_hi = std::min<uint64_t>(a0.size(), lit_hi + z[1] + z[2] + z[3]);
    uint8_t *d_in, *d_out, *d_tmp, *h_out; int* d_st; int h_st; cudaStream_t s; cudaEvent_t ev; size_t tcap = 0;
    CK(cudaMalloc(&d_in, a0.size() + 256)); CK(cudaMalloc(&d_out, orig.size() + 256)); CK(cudaMalloc(&d_st, 4)); CK(cudaHostAlloc(&h_out, orig.size() + 256, cudaHostAllocDefault));
    CK(cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking)); CK(cudaEventCreateWithFlags(&ev, cudaEventDisableTiming)); d_tmp = nullptr;
    std::mt19937_64 g(4242); const char* kinds[7] = {"bit flip", "random bytes", "zeroed run", "truncation", "header/table", "literal stream", "token streams"};
    long refused[7] = {0}, caught[7] = {0}, harmless[7] = {0}, silent[7] = {0}, caught_h[7] = {0}, harmless_h[7] = {0}, silent_h[7] = {0}, hang = 0;
    std::vector<uint8_t> a; const double t0 = now_s();
    for (int it = 0; it < N; it++) {
        const int k = it % 7; a = a0; auto rpos = [&](uint64_t lo, uint64_t hi) { return hi > lo ? lo + g() % (hi - lo) : g() % a.size(); };
        switch (k) {
            case 0: { const uint64_t p = g() % a.size(); a[p] ^= (uint8_t)(1u << (g() % 8)); break; }
            case 1: { const int m = 1 + (int)(g() % 8); for (int j = 0; j < m; j++) a[g() % a.size()] = (uint8_t)g(); break; }
            case 2: { const uint64_t p = g() % a.size(), L = 1 + g() % 256; memset(a.data() + p, 0, std::min<uint64_t>(L, a.size() - p)); break; }
            case 3: a.resize(68 + g() % (a.size() - 68)); break;
            case 4: a[rpos(0, tab_end)] ^= (uint8_t)(1u << (g() % 8)); break;
            case 5: a[rpos(lit_lo, lit_hi)] ^= (uint8_t)(1u << (g() % 8)); break;
            case 6: a[rpos(lit_hi, tok_hi)] ^= (uint8_t)(1u << (g() % 8)); break;
        }
        aceapex_gpu_plan* pl = aceapex_gpu_plan_create(a.data(), a.size(), 0);
        if (!pl) { refused[k]++; continue; }
        const size_t tb = aceapex_gpu_temp_bytes(pl), ob = aceapex_gpu_output_bytes(pl);
        if (ob > orig.size() + 256) { caught[k]++; caught_h[k]++; aceapex_gpu_plan_destroy(pl); continue; }   // another size: a plan the caller sizes; not ours to run
        if (tb > tcap) { if (d_tmp) cudaFree(d_tmp); tcap = tb + (tb >> 3); CK(cudaMalloc(&d_tmp, tcap)); }
        CK(cudaMemcpy(d_in, a.data(), a.size(), cudaMemcpyHostToDevice));
        for (int pass = 0; pass < 2; pass++) {
            CK(cudaMemsetAsync(d_out, 0xA5, ob, s));
            if (aceapex_gpu_decompress_async(pl, d_in, d_out, d_tmp, d_st, pass ? ACEAPEX_GPU_VERIFY_XXH3 : 0, s)) { (pass ? caught_h : caught)[k]++; continue; }
            CK(cudaEventRecord(ev, s));
            if (!wait_ev(ev, 10.0)) { hang++; printf("[stress] HANG at copy %d (%s, pass %d): stopped\n", it, kinds[k], pass); goto out; }
            CK(cudaMemcpy(&h_st, d_st, 4, cudaMemcpyDeviceToHost));
            bool same = false;
            if (ob == orig.size()) { CK(cudaMemcpy(h_out, d_out, ob, cudaMemcpyDeviceToHost)); same = memcmp(h_out, orig.data(), ob) == 0; }
            if (h_st) (pass ? caught_h : caught)[k]++; else if (same) (pass ? harmless_h : harmless)[k]++; else (pass ? silent_h : silent)[k]++;
        }
        aceapex_gpu_plan_destroy(pl);
    }
out:
    long R = 0, C = 0, H = 0, S = 0, Ch = 0, Hh = 0, Sh = 0;
    printf("[stress] %s: %d corrupt copies in %.1f s; per kind: refused by the plan / caught on the device / harmless / SILENT, then with XXH3\n", base(argv[2]), N, now_s() - t0);
    for (int k = 0; k < 7; k++) { printf("[stress]   %-15s %5ld / %5ld / %5ld / %3ld   | %5ld / %5ld / %3ld\n", kinds[k], refused[k], caught[k], harmless[k], silent[k], caught_h[k], harmless_h[k], silent_h[k]);
        R += refused[k]; C += caught[k]; H += harmless[k]; S += silent[k]; Ch += caught_h[k]; Hh += harmless_h[k]; Sh += silent_h[k]; }
    printf("[stress] total: refused %ld, caught %ld, harmless %ld, silent %ld (no hash: bytes stored raw carry no check of their own); with XXH3: caught %ld, harmless %ld, silent %ld; hangs %ld\n", R, C, H, S, Ch, Hh, Sh, hang);
    printf("H4ROW\t%s\t%d\t%ld\t%ld\t%ld\t%ld\t%ld\t%ld\t%s\n", base(argv[2]), N, R, C + Ch, H, S, Sh, hang, (!hang && !Sh) ? "ok" : "FAILED");
    return (!hang && !Sh) ? 0 : 5;
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc < 3) { fprintf(stderr, "usage: %s sat|pcie|ra|stress <archive> ...\n", argv[0]); return 1; }
    if (!strcmp(argv[1], "sat")) return t_sat(argc, argv);
    if (!strcmp(argv[1], "pcie") && argc >= 4) return t_pcie(argc, argv);
    if ((!strcmp(argv[1], "ra") || !strcmp(argv[1], "ra-cpu")) && argc >= 4) return t_ra(argc, argv);
    if (!strcmp(argv[1], "stress") && argc >= 4) return t_stress(argc, argv);
    fprintf(stderr, "bad arguments\n"); return 1;
}
