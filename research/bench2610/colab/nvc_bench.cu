// nvc_bench.cu <file> <algo: lz4|zstd|gdeflate|ans> [chunk bytes = 65536] - nvCOMP batched C++ API (nvCOMP 5), device to
// device. Data preparation (outside timing): the file is cut into chunks, copied to the device and compressed there by the
// batched compressor. Timed: only the batched decompress call, CUDA events around it, input and output already in VRAM;
// 3 warm-ups + 9 timed runs, median / min / max / raw. After timing: the output copied back and compared with the file
// byte for byte (and every chunk status == success). H2D: the compressed bytes (packed) from pinned host memory to the
// device, CUDA events, median of 9 after 3 warm-ups. Prints one NVROW line.
#include <nvcomp/lz4.h>
#include <nvcomp/zstd.h>
#include <nvcomp/gdeflate.h>
#include <nvcomp/ans.h>
#include <cuda_runtime.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { printf("CUDA %s: %s\n", #x, cudaGetErrorString(e_)); exit(2); } } while (0)
#define NV(x) do { nvcompStatus_t s_ = (x); if (s_ != nvcompSuccess) { printf("nvCOMP %s: status %d\n", #x, (int)s_); exit(3); } } while (0)

// one set of entry points per algorithm (nvCOMP 5 names; default options)
#define ALGO(NAME)                                                                                                         \
    struct NAME##A {                                                                                                       \
        static void ctemp(size_t n, size_t mc, size_t* t, size_t tot) { NV(nvcompBatched##NAME##CompressGetTempSizeAsync(n, mc, nvcompBatched##NAME##CompressDefaultOpts, t, tot)); } \
        static void cmax(size_t mc, size_t* m) { NV(nvcompBatched##NAME##CompressGetMaxOutputChunkSize(mc, nvcompBatched##NAME##CompressDefaultOpts, m)); } \
        static void comp(const void* const* ip, const size_t* is, size_t mc, size_t n, void* t, size_t tb, void* const* op, size_t* os, nvcompStatus_t* st, cudaStream_t s) { \
            NV(nvcompBatched##NAME##CompressAsync(ip, is, mc, n, t, tb, op, os, nvcompBatched##NAME##CompressDefaultOpts, st, s)); } \
        static void dtemp(size_t n, size_t mc, size_t* t, size_t tot) { NV(nvcompBatched##NAME##DecompressGetTempSizeAsync(n, mc, nvcompBatched##NAME##DecompressDefaultOpts, t, tot)); } \
        static nvcompStatus_t decomp(const void* const* cp, const size_t* cs, const size_t* us, size_t* act, size_t n, void* t, size_t tb, void* const* op, nvcompStatus_t* st, cudaStream_t s) { \
            return nvcompBatched##NAME##DecompressAsync(cp, cs, us, act, n, t, tb, op, nvcompBatched##NAME##DecompressDefaultOpts, st, s); } \
    };
ALGO(LZ4) ALGO(Zstd) ALGO(Gdeflate) ALGO(ANS)

template <class A> static int run(const char* path, const char* name, size_t CH) {
    FILE* f = fopen(path, "rb"); if (!f) { perror(path); return 1; }
    fseek(f, 0, SEEK_END); const size_t n = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<char> h(n); if (fread(h.data(), 1, n, f) != n) return 1; fclose(f);
    const size_t B = (n + CH - 1) / CH;
    cudaStream_t s; CK(cudaStreamCreate(&s));
    char* din; CK(cudaMalloc(&din, n)); CK(cudaMemcpy(din, h.data(), n, cudaMemcpyHostToDevice));
    std::vector<void*> ip(B); std::vector<size_t> is(B);
    for (size_t i = 0; i < B; i++) { ip[i] = din + i * CH; is[i] = std::min(CH, n - i * CH); }
    void** dip; size_t* dis; CK(cudaMalloc(&dip, B * sizeof(void*))); CK(cudaMalloc(&dis, B * sizeof(size_t)));
    CK(cudaMemcpy(dip, ip.data(), B * sizeof(void*), cudaMemcpyHostToDevice)); CK(cudaMemcpy(dis, is.data(), B * sizeof(size_t), cudaMemcpyHostToDevice));
    size_t mco = 0; A::cmax(CH, &mco); size_t ct = 0; A::ctemp(B, CH, &ct, n);
    char* dcb; CK(cudaMalloc(&dcb, B * mco)); void* dct; CK(cudaMalloc(&dct, std::max<size_t>(ct, 1)));
    std::vector<void*> cp(B); for (size_t i = 0; i < B; i++) cp[i] = dcb + i * mco;
    void** dcp; size_t* dcs; nvcompStatus_t* dst; CK(cudaMalloc(&dcp, B * sizeof(void*))); CK(cudaMalloc(&dcs, B * sizeof(size_t))); CK(cudaMalloc(&dst, B * sizeof(nvcompStatus_t)));
    CK(cudaMemcpy(dcp, cp.data(), B * sizeof(void*), cudaMemcpyHostToDevice));
    A::comp((const void* const*)dip, dis, CH, B, dct, ct, (void* const*)dcp, dcs, dst, s); CK(cudaStreamSynchronize(s));
    std::vector<size_t> cs(B); CK(cudaMemcpy(cs.data(), dcs, B * sizeof(size_t), cudaMemcpyDeviceToHost));
    size_t csum = 0; for (auto x : cs) csum += x;
    // decompression buffers (output into a separate device buffer)
    char* dout; CK(cudaMalloc(&dout, n)); std::vector<void*> op(B); for (size_t i = 0; i < B; i++) op[i] = dout + i * CH;
    void** dop; size_t* dact; CK(cudaMalloc(&dop, B * sizeof(void*))); CK(cudaMalloc(&dact, B * sizeof(size_t)));
    CK(cudaMemcpy(dop, op.data(), B * sizeof(void*), cudaMemcpyHostToDevice));
    size_t dt = 0; A::dtemp(B, CH, &dt, n); void* ddt; CK(cudaMalloc(&ddt, std::max<size_t>(dt, 1)));
    cudaEvent_t a, b; CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b)); std::vector<float> t;
    for (int r = 0; r < 12; r++) {
        CK(cudaEventRecord(a, s));
        NV(A::decomp((const void* const*)dcp, dcs, dis, dact, B, ddt, dt, (void* const*)dop, dst, s));
        CK(cudaEventRecord(b, s)); CK(cudaEventSynchronize(b)); float ms; CK(cudaEventElapsedTime(&ms, a, b)); if (r >= 3) t.push_back(ms);
    }
    std::vector<char> back(n); CK(cudaMemcpy(back.data(), dout, n, cudaMemcpyDeviceToHost));
    std::vector<nvcompStatus_t> st(B); CK(cudaMemcpy(st.data(), dst, B * sizeof(nvcompStatus_t), cudaMemcpyDeviceToHost));
    bool ok = !memcmp(back.data(), h.data(), n); for (auto x : st) ok &= x == nvcompSuccess;
    // H2D of the packed compressed bytes
    char* hp; CK(cudaMallocHost(&hp, csum)); char* dp; CK(cudaMalloc(&dp, csum)); std::vector<float> th;
    for (int r = 0; r < 12; r++) { CK(cudaEventRecord(a, s)); CK(cudaMemcpyAsync(dp, hp, csum, cudaMemcpyHostToDevice, s)); CK(cudaEventRecord(b, s)); CK(cudaEventSynchronize(b));
        float ms; CK(cudaEventElapsedTime(&ms, a, b)); if (r >= 3) th.push_back(ms); }
    std::vector<float> ts = t; std::sort(ts.begin(), ts.end()); std::sort(th.begin(), th.end());
    const float med = ts[ts.size() / 2], hmed = th[th.size() / 2];
    printf("NVROW\t%s\t%s\tchunk %zu\t%zu chunks\tcompressed %zu B\tratio %.4f\tdecode median %.3f ms (min %.3f max %.3f) = %.2f GB/s\traw", path, name, CH, B, csum, (double)n / csum, med, ts.front(), ts.back(), n / med / 1e6);
    for (auto x : t) printf(" %.3f", x);
    printf("\tH2D %.3f ms\tpath %.2f GB/s\t%s\n", hmed, n / (med + hmed) / 1e6, ok ? "output == original" : "OUTPUT DIFFERS");
    return ok ? 0 : 4;
}
int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: nvc_bench <file> lz4|zstd|gdeflate|ans [chunk]\n"); return 1; }
    const size_t CH = argc > 3 ? strtoull(argv[3], 0, 10) : 65536; const std::string a = argv[2];
    if (a == "lz4") return run<LZ4A>(argv[1], "LZ4", CH);
    if (a == "zstd") return run<ZstdA>(argv[1], "Zstd", CH);
    if (a == "gdeflate") return run<GdeflateA>(argv[1], "GDeflate", CH);
    if (a == "ans") return run<ANSA>(argv[1], "ANS", CH);
    return 1;
}
