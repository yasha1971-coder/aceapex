// gpu_stream.cu - an output larger than the card: the archive on the device once, the original decoded in windows of
// WIN bytes through aceapex_gpu_decompress_range_async, two windows in flight (decode of window i+1 on one stream while
// window i is copied to pinned host memory on the other), the host hashing the windows in order with XXH3 streaming;
// the hash of the whole output must equal the archive header's. With an original file given, every window is also
// compared with it (byte for byte, read window by window). Times: decode only (events) and wall (decode + D2H + hash).
// Build: nvcc -std=c++17 -O3 -arch=sm_XX -Isrc [-DACEAPEX_GPU_NVCOMP -I<nvcomp>/include] scripts/gpu_stream.cu
//        src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp [-l:libnvcomp.so.5 -lzstd]
// Usage: gpu_stream <archive.aet> [window_MiB=1024] [original]
// Last line: STREAMROW <tab> archive bytes output windows window_MiB decode_s wall_s GB/s_wall hash(match|DIFFERS) cmp
#include "aceapex_gpu.h"
#define XXH_INLINE_ALL
#include "xxhash.h"
#include <cuda_runtime.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { printf("CUDA %s @%d: %s\n", #x, __LINE__, cudaGetErrorString(e_)); exit(2); } } while (0)
static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc < 2) { fprintf(stderr, "usage: %s <archive.aet> [window_MiB] [original]\n", argv[0]); return 1; }
    FILE* f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END); std::vector<uint8_t> a((size_t)ftell(f)); fseek(f, 0, SEEK_SET);
    if (fread(a.data(), 1, a.size(), f) != a.size()) return 1;
    fclose(f);
    const uint64_t WIN = (uint64_t)(argc > 2 ? atoll(argv[2]) : 1024) << 20;
    FILE* fo = argc > 3 ? fopen(argv[3], "rb") : nullptr;
    aceapex_gpu_plan* plan = aceapex_gpu_plan_create(a.data(), a.size(), 0);
    if (!plan) { printf("plan_create failed: %d\n", aceapex_gpu_last_error()); return 3; }
    const uint64_t n = aceapex_gpu_output_bytes(plan), nw = (n + WIN - 1) / WIN;
    uint64_t hx; memcpy(&hx, a.data() + 28, 8);
    size_t tb = aceapex_gpu_range_temp_bytes(plan, WIN), fr = 0, tot = 0; CK(cudaMemGetInfo(&fr, &tot));
    printf("[stream] archive %zu B, output %llu B in %llu windows of %llu MiB; device: archive + 2 x (temp %.1f GB + window) on %.1f GB free\n",
           a.size(), (unsigned long long)n, (unsigned long long)nw, (unsigned long long)(WIN >> 20), tb / 1e9, fr / 1e9);
    // two windows in flight need two temps (each holds the whole stream layout); one when two do not fit the card
    const int NB = ((double)a.size() + 2.0 * ((double)tb + (double)WIN) < 0.92 * (double)fr) ? 2 : 1;
    printf("[stream] %d window%s in flight\n", NB, NB > 1 ? "s" : "");
    uint8_t* d_in; CK(cudaMalloc(&d_in, a.size())); CK(cudaMemcpy(d_in, a.data(), a.size(), cudaMemcpyHostToDevice));
    uint8_t *d_out[2], *d_tmp[2], *h_out[2]; int* d_st[2]; cudaStream_t s[2]; cudaEvent_t e0[2], e1[2], ed[2];
    for (int k = 0; k < NB; k++) { CK(cudaMalloc(&d_out[k], WIN)); CK(cudaMalloc(&d_tmp[k], tb)); CK(cudaMalloc(&d_st[k], 4)); CK(cudaHostAlloc(&h_out[k], WIN, cudaHostAllocDefault));
        CK(cudaStreamCreate(&s[k])); CK(cudaEventCreate(&e0[k])); CK(cudaEventCreate(&e1[k])); CK(cudaEventCreate(&ed[k])); }
    XXH3_state_t* hs = XXH3_createState(); XXH3_64bits_reset(hs);
    std::vector<uint8_t> ref(fo ? WIN : 0); bool cmp_ok = true, st_ok = true; double dec = 0;
    const double t0 = now_s();
    auto launch = [&](uint64_t w) { const int k = (int)(w % NB); const uint64_t off = w * WIN, len = off + WIN <= n ? WIN : n - off;
        CK(cudaEventRecord(e0[k], s[k]));
        const int r = aceapex_gpu_decompress_range_async(plan, d_in, off, len, d_out[k], d_tmp[k], d_st[k], s[k]);
        if (r) { printf("range call: %d\n", r); exit(4); }
        CK(cudaEventRecord(e1[k], s[k])); CK(cudaMemcpyAsync(h_out[k], d_out[k], len, cudaMemcpyDeviceToHost, s[k])); CK(cudaEventRecord(ed[k], s[k])); };
    if (nw) launch(0);
    for (uint64_t w = 0; w < nw; w++) {
        if (NB == 2 && w + 1 < nw) launch(w + 1);
        const int k = (int)(w % NB); const uint64_t off = w * WIN, len = off + WIN <= n ? WIN : n - off;
        CK(cudaEventSynchronize(ed[k])); float ms = 0; CK(cudaEventElapsedTime(&ms, e0[k], e1[k])); dec += ms / 1e3;
        int st = -1; CK(cudaMemcpy(&st, d_st[k], 4, cudaMemcpyDeviceToHost)); if (st) { st_ok = false; printf("[stream] window %llu: status %d\n", (unsigned long long)w, st); }
        XXH3_64bits_update(hs, h_out[k], len);
        if (fo) { if (fread(ref.data(), 1, len, fo) != len || memcmp(ref.data(), h_out[k], len)) { if (cmp_ok) printf("[stream] window %llu differs from the original\n", (unsigned long long)w); cmp_ok = false; } }
        if (NB == 1 && w + 1 < nw) launch(w + 1);
    }
    const double wall = now_s() - t0; const uint64_t h = XXH3_64bits_digest(hs); XXH3_freeState(hs);
    const bool hash_ok = h == hx && st_ok;
    printf("[stream] %llu windows: decode %.3f s (sum of windows), wall %.3f s -> %.2f GB/s with D2H and host hash; XXH3 %016llx %s header%s\n",
           (unsigned long long)nw, dec, wall, n / wall / 1e9, (unsigned long long)h, hash_ok ? "==" : "!=", fo ? (cmp_ok ? ", every window == the original" : ", WINDOWS DIFFER") : "");
    printf("STREAMROW\t%s\t%zu\t%llu\t%llu\t%llu\t%.3f\t%.3f\t%.2f\t%s\t%s\n", argv[1], a.size(), (unsigned long long)n, (unsigned long long)nw, (unsigned long long)(WIN >> 20),
           dec, wall, n / wall / 1e9, hash_ok ? "match" : "DIFFERS", fo ? (cmp_ok ? "match" : "DIFFERS") : "-");
    if (fo) fclose(fo);
    aceapex_gpu_plan_destroy(plan);
    return hash_ok && cmp_ok ? 0 : 5;
}
