// refrel3_gpu.cu - refrel3 windows on the GPU (research; format refrel3.h), the stages of run_colab_r3.sh.
// The T2T reference resident decoded; per assembly the refrel3 payload (one rANS stream per RR_BS block), the block
// offsets, the carried block states and the static tables resident. No host selection: the grid is (window x blocks
// per window); a CUDA block takes its refrel3 block from the window's start, thread 0 decodes the block's stream into ops
// (r3_decode_block, the code the CPU tool runs), the threads execute literal / reference / reverse-complement copies in
// parallel, one warp the self copies in order, and the window's part is written.
//   s1 <ref.fa> <prefix> <asm.fa> [<prefix> <asm.fa>]...  full decode of the first assembly on the card (XXH3 of the
//        FASTA rebuilt from it == XXH3 of the file) + 100 000 windows W = 256 B .. 1 MiB over all given assemblies,
//        each == the CPU refrel3 decode of the same window
//   s2 <ref.fa> <prefix> <asm.fa>      speed of light: the same windows cut from the raw bases resident; D2D memcpy GB/s
//   s3 <ref.fa> <prefix> <asm.fa>      windows/s by W; grid windows per batch x threads per CUDA block; clock64 split of
//        a block's time into thread 0's rANS decode and the copies; occupancy per block size
//   curves <ref.fa> <prefix> <asm.fa>  windows/s by W at 128 threads (S4: one binary per -DRR_BS)
//   one <ref.fa> <prefix> <W> <n> <tpb>  one batch (for ncu)
// Build: nvcc -std=c++17 -O3 -arch=native -lineinfo -Isrc -Iresearch/refrel -c research/refrel/refrel3_gpu.cu, link with
// src/aceapex_api.cpp -lzstd -lpthread
#define RR3_NO_MAIN
#include "refrel3.cpp"
#define XXH_INLINE_ALL
#include "xxhash.h"
#include <cuda_runtime.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { printf("CUDA %s @%d: %s\n", #x, __LINE__, cudaGetErrorString(e_)); exit(2); } } while (0)
static const uint32_t KOPS = 1024;
static const size_t SMEM = KOPS * sizeof(RrOp) + 2 * RR_BS;

struct Dev3 { uint8_t* P = nullptr; uint64_t* off = nullptr; R3Diag* st = nullptr; R3Tab* T = nullptr; uint64_t n = 0, nb = 0, bytes = 0, payload = 0; };
static Dev3 load_dev3(const Arch3& X) {
    Dev3 D; D.n = X.M.n; D.nb = X.M.nb;
    if (!X.M.low.empty()) { printf("lower-case runs present - not handled on the card in this tool\n"); exit(3); }
    CK(cudaMalloc(&D.P, X.P.size() + 64)); CK(cudaMemcpy(D.P, X.P.data(), X.P.size(), cudaMemcpyHostToDevice));
    CK(cudaMalloc(&D.off, X.off.size() * 8)); CK(cudaMemcpy(D.off, X.off.data(), X.off.size() * 8, cudaMemcpyHostToDevice));
    CK(cudaMalloc(&D.st, X.st.size() * sizeof(R3Diag))); CK(cudaMemcpy(D.st, X.st.data(), X.st.size() * sizeof(R3Diag), cudaMemcpyHostToDevice));
    CK(cudaMalloc(&D.T, sizeof(R3Tab))); CK(cudaMemcpy(D.T, X.T, sizeof(R3Tab), cudaMemcpyHostToDevice));
    D.payload = X.P.size(); D.bytes = X.P.size() + X.off.size() * 8 + X.st.size() * sizeof(R3Diag) + sizeof(R3Tab);
    return D;
}

template <bool PROF>
__global__ void r3_kernel(const uint8_t* __restrict__ P, const uint64_t* __restrict__ off, const R3Diag* __restrict__ st, const R3Tab* __restrict__ T,
                          const uint8_t* __restrict__ ref, uint64_t ref_n, uint64_t n_bases, const uint64_t* __restrict__ woff, uint32_t W, uint32_t bpw,
                          uint8_t* __restrict__ out, int* status, unsigned long long* prof) {
    extern __shared__ __align__(16) uint8_t sm[];
    RrOp* ops = (RrOp*)sm; uint8_t* blk = sm + KOPS * sizeof(RrOp); uint8_t* lit = blk + RR_BS; __shared__ int nk;
    const uint32_t w = blockIdx.x / bpw, j = blockIdx.x % bpw; const uint64_t s = woff[w];
    const uint64_t b0 = s / RR_BS, b1 = (s + W - 1) / RR_BS, b = b0 + j; if (b > b1) return;
    const uint64_t bst = b * RR_BS; const uint32_t blen = (uint32_t)min((uint64_t)RR_BS, n_bases - bst);
    long long t0 = 0, t1 = 0;
    if (PROF && threadIdx.x == 0) t0 = clock64();
    if (threadIdx.x == 0) nk = r3_decode_block(P + off[b], (uint32_t)(off[b + 1] - off[b]), T, ref, ref_n, blen, st[b], ops, KOPS, lit, RR_BS);
    if (PROF && threadIdx.x == 0) t1 = clock64();
    __syncthreads();
    const int k = nk; if (k < 0) { if (threadIdx.x == 0) atomicOr(status, 1); return; }
    for (int q = 0; q < k; q++) { const RrOp op = ops[q];
        if (op.kind == 0) for (uint32_t i = threadIdx.x; i < op.len; i += blockDim.x) blk[op.dst + i] = lit[op.src + i];
        else if (op.kind == 1) for (uint32_t i = threadIdx.x; i < op.len; i += blockDim.x) blk[op.dst + i] = ref[op.src + i];
        else if (op.kind == 3) for (uint32_t i = threadIdx.x; i < op.len; i += blockDim.x) blk[op.dst + i] = rr_comp(ref[op.src + op.len - 1 - i]); }
    __syncthreads();
    if (threadIdx.x < 32) for (int q = 0; q < k; q++) { const RrOp op = ops[q]; if (op.kind != 2) continue;
        const uint32_t dist = op.dst - (uint32_t)op.src;
        for (uint32_t c = 0; c < op.len;) { const uint32_t step = min(dist, op.len - c);
            for (uint32_t i = threadIdx.x; i < step; i += 32) blk[op.dst + c + i] = blk[op.src + c + i];
            __syncwarp(); c += step; } }
    __syncthreads();
    const uint64_t a = max(s, bst), e = min(s + W, bst + blen);
    for (uint64_t x = a + threadIdx.x; x < e; x += blockDim.x) out[(uint64_t)w * W + (x - s)] = blk[x - bst];
    if (PROF) { __syncthreads(); if (threadIdx.x == 0) { const long long t2 = clock64(); prof[2 * blockIdx.x] = (unsigned long long)(t1 - t0); prof[2 * blockIdx.x + 1] = (unsigned long long)(t2 - t1); } }
}
// ---------------------------------------------------------------- queue kernel: one warp per refrel3 block
// Lane 0 decodes (r3_decode_stream): literals straight into the block buffer, copies into a ring of QN ops in shared
// memory; lanes 1..31 take the ops in order as they come and execute them (reference / reverse complement / self), then
// all 32 lanes write the window's part. Shared memory: the block buffer (RR_BS) + the ring - no op array, no literal
// buffer. Every wait is bounded (status 4 instead of a hang).
struct QOp { uint32_t src; uint16_t dst, len; uint32_t kind; };
#define QN 64
#define QSPIN (1u << 26)
static const size_t QSMEM = RR_BS + QN * sizeof(QOp);
struct QSink { uint8_t* blk; QOp* q; volatile int* head; volatile int* tail; int* status;
    __device__ bool lit(uint32_t o, uint32_t, uint8_t b) { blk[o] = b; return true; }
    __device__ bool op(uint32_t kind, uint64_t src, uint32_t dst, uint32_t len) {
        if (kind == 0) return true;                                      // literals are already in the block buffer
        const int h = *head; uint32_t spin = 0;
        while (h - *tail >= QN) { if (++spin > QSPIN) { atomicOr(status, 4); return false; } }
        QOp& e = q[h % QN]; e.src = (uint32_t)src; e.dst = (uint16_t)dst; e.len = (uint16_t)len; e.kind = kind;
        __threadfence_block(); *head = h + 1; return true; } };
__global__ void __launch_bounds__(32, 16) r3q_kernel(const uint8_t* __restrict__ P, const uint64_t* __restrict__ off, const R3Diag* __restrict__ st, const R3Tab* __restrict__ T,
                          const uint8_t* __restrict__ ref, uint64_t ref_n, uint64_t n_bases, const uint64_t* __restrict__ woff, uint32_t W, uint32_t bpw,
                          uint8_t* __restrict__ out, int* status) {
    extern __shared__ __align__(16) uint8_t sm[];
    uint8_t* blk = sm; QOp* q = (QOp*)(sm + RR_BS);
    __shared__ int s_head, s_tail, s_done, s_nk;
    volatile int* head = &s_head; volatile int* tail = &s_tail; volatile int* done = &s_done;
    const uint32_t lane = threadIdx.x;
    const uint32_t w = blockIdx.x / bpw, j = blockIdx.x % bpw; const uint64_t s = woff[w];
    const uint64_t b0 = s / RR_BS, b1 = (s + W - 1) / RR_BS, b = b0 + j; if (b > b1) return;
    const uint64_t bst = b * RR_BS; const uint32_t blen = (uint32_t)min((uint64_t)RR_BS, n_bases - bst);
    if (lane == 0) { *head = 0; *tail = 0; *done = 0; }
    __syncwarp();
    if (lane == 0) {
        QSink sk; sk.blk = blk; sk.q = q; sk.head = head; sk.tail = tail; sk.status = status;
        s_nk = r3_decode_stream(P + off[b], (uint32_t)(off[b + 1] - off[b]), T, ref, ref_n, blen, st[b], sk);
        __threadfence_block(); *done = s_nk < 0 ? 2 : 1;
    } else {
        const unsigned m = 0xFFFFFFFEu; int next = 0; uint32_t spin = 0;
        for (;;) {
            int h = 0, d = 0; if (lane == 1) { d = *done; __threadfence_block(); h = *head; }   // done first: then head is final
            h = __shfl_sync(m, h, 1); d = __shfl_sync(m, d, 1);
            if (next < h) {
                const QOp e = q[next % QN];
                if (e.kind == 1) for (uint32_t i = lane - 1; i < e.len; i += 31) blk[e.dst + i] = ref[e.src + i];
                else if (e.kind == 3) for (uint32_t i = lane - 1; i < e.len; i += 31) blk[e.dst + i] = rr_comp(ref[e.src + e.len - 1 - i]);
                else { const uint32_t dist = (uint32_t)e.dst - e.src;
                    for (uint32_t c = 0; c < e.len;) { const uint32_t step = min(dist, (uint32_t)e.len - c);
                        for (uint32_t i = lane - 1; i < step; i += 31) blk[e.dst + c + i] = blk[e.src + c + i];
                        __syncwarp(m); c += step; } }
                __syncwarp(m); next++; if (lane == 1) { __threadfence_block(); *tail = next; } spin = 0;
            } else if (d) { if (next >= h) break; }
            else if (++spin > QSPIN) { if (lane == 1) atomicOr(status, 4); break; }
        }
    }
    __syncwarp();
    if (s_nk < 0) { if (lane == 0) atomicOr(status, 1); return; }
    const uint64_t a = max(s, bst), e = min(s + W, bst + blen);
    for (uint64_t x = a + lane; x < e; x += 32) out[(uint64_t)w * W + (x - s)] = blk[x - bst];
}

// speed of light: the windows cut from the raw bases resident
__global__ void raw_kernel(const uint8_t* __restrict__ raw, const uint64_t* __restrict__ woff, uint32_t W, uint8_t* __restrict__ out) {
    const uint64_t s = woff[blockIdx.x]; uint8_t* o = out + (uint64_t)blockIdx.x * W;
    for (uint32_t i = threadIdx.x; i < W; i += blockDim.x) o[i] = raw[s + i];
}

struct Ctx { std::vector<uint8_t> R; uint8_t* d_ref = nullptr; cudaStream_t s; int* d_st = nullptr; };
static void ctx_init(Ctx& C, const char* fa) {
    Fasta RF = read_fasta(fa); C.R = upper(RF.b);
    CK(cudaMalloc(&C.d_ref, C.R.size())); CK(cudaMemcpy(C.d_ref, C.R.data(), C.R.size(), cudaMemcpyHostToDevice));
    CK(cudaStreamCreateWithFlags(&C.s, cudaStreamNonBlocking)); CK(cudaMalloc(&C.d_st, 4));
    CK(cudaFuncSetAttribute(r3_kernel<false>, cudaFuncAttributeMaxDynamicSharedMemorySize, (int)SMEM));
    CK(cudaFuncSetAttribute(r3_kernel<true>, cudaFuncAttributeMaxDynamicSharedMemorySize, (int)SMEM));
    CK(cudaFuncSetAttribute(r3q_kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, (int)QSMEM));
}
static uint32_t bpw_of(uint32_t W) { return (W + RR_BS - 1) / RR_BS + 1; }
// tpb == 0: the queue kernel (one warp per block); else the classic kernel with tpb threads
static void launch(const Ctx& C, const Dev3& D, const uint64_t* d_woff, uint32_t n, uint32_t W, uint32_t tpb, uint8_t* d_out, unsigned long long* prof = nullptr) {
    const uint32_t bpw = bpw_of(W);
    if (tpb == 0) r3q_kernel<<<n * bpw, 32, QSMEM, C.s>>>(D.P, D.off, D.st, D.T, C.d_ref, C.R.size(), D.n, d_woff, W, bpw, d_out, C.d_st);
    else if (prof) r3_kernel<true><<<n * bpw, tpb, SMEM, C.s>>>(D.P, D.off, D.st, D.T, C.d_ref, C.R.size(), D.n, d_woff, W, bpw, d_out, C.d_st, prof);
    else r3_kernel<false><<<n * bpw, tpb, SMEM, C.s>>>(D.P, D.off, D.st, D.T, C.d_ref, C.R.size(), D.n, d_woff, W, bpw, d_out, C.d_st, nullptr);
}
static int status(const Ctx& C) { int v = -1; CK(cudaStreamSynchronize(C.s)); CK(cudaGetLastError()); CK(cudaMemcpy(&v, C.d_st, 4, cudaMemcpyDeviceToHost)); return v; }
static const uint32_t WS[7] = {256, 1024, 4096, 16384, 65536, 262144, 1048576};
static uint32_t default_n(uint32_t W) { return (uint32_t)std::min<uint64_t>(65536, std::max<uint64_t>(64, (1ull << 29) / W)); }
static std::vector<uint64_t> rand_offs(uint64_t n_bases, uint32_t W, uint32_t n, uint64_t seed) { std::mt19937_64 g(seed); std::vector<uint64_t> v(n); for (auto& x : v) x = g() % (n_bases - W + 1); return v; }
static uint64_t* upload(const std::vector<uint64_t>& v) { uint64_t* d; CK(cudaMalloc(&d, v.size() * 8)); CK(cudaMemcpy(d, v.data(), v.size() * 8, cudaMemcpyHostToDevice)); return d; }
// windows/s of NB batches back to back (different offsets each), the last batch's status
static double rate(const Ctx& C, const Dev3& D, uint32_t W, uint32_t n, uint32_t tpb, int NB, uint64_t seed, int* st) {
    std::vector<uint64_t*> d(NB); for (int k = 0; k < NB; k++) d[k] = upload(rand_offs(D.n, W, n, seed + k));
    uint8_t* out; CK(cudaMalloc(&out, (size_t)n * W)); CK(cudaMemset(C.d_st, 0, 4));
    launch(C, D, d[0], n, W, tpb, out); *st = status(C);
    const double t0 = now_s(); for (int k = 0; k < NB; k++) launch(C, D, d[k], n, W, tpb, out); *st |= status(C); const double t = now_s() - t0;
    for (auto p : d) cudaFree(p); cudaFree(out); return (double)n * NB / t;
}

// ---------------------------------------------------------------- S1
static int cmd_s1(int argc, char** argv) {
    Ctx C; ctx_init(C, argv[2]); std::vector<Arch3> X; std::vector<Dev3> D; std::vector<std::string> fa;
    for (int a = 3; a + 1 < argc; a += 2) { X.push_back(load3(argv[a])); D.push_back(load_dev3(X.back())); fa.push_back(argv[a + 1]); }
    cudaDeviceProp pr; CK(cudaGetDeviceProperties(&pr, 0)); printf("[s1] %s | %zu assemblies | reference %.2f GB\n", pr.name, X.size(), C.R.size() / 1e9);
    // full decode of the first on the card: 1 MiB windows covering it (the last one ends at the end)
    { const Dev3& d = D[0]; const uint32_t W = 1u << 20; const uint32_t n = (uint32_t)((d.n + W - 1) / W); std::vector<uint64_t> o(n); for (uint32_t i = 0; i < n; i++) o[i] = std::min<uint64_t>((uint64_t)i * W, d.n - W);
      uint64_t* dw = upload(o); uint8_t* out; CK(cudaMalloc(&out, (size_t)n * W));
      for (uint32_t kern : {128u, 0u}) { CK(cudaMemset(C.d_st, 0, 4)); CK(cudaMemset(out, 0, (size_t)n * W));
      const double t0 = now_s(); launch(C, d, dw, n, W, kern, out); const int st = status(C); const double t = now_s() - t0;
      std::vector<uint8_t> h((size_t)n * W), A(d.n); CK(cudaMemcpy(h.data(), out, h.size(), cudaMemcpyDeviceToHost));
      for (uint32_t i = 0; i < n; i++) memcpy(&A[o[i]], &h[(size_t)i * W], W);
      std::string fasta; fasta.reserve(d.n + d.n / 60 + 1024);
      for (auto& r : X[0].M.rec) { fasta += '>'; fasta += r.hdr; fasta += '\n'; for (uint64_t x = 0; x < r.len; x += r.lw) { fasta.append((const char*)&A[r.boff + x], std::min<uint64_t>(r.lw, r.len - x)); fasta += '\n'; } }
      const std::vector<uint8_t> file = slurp(fa[0]); const uint64_t h1 = XXH3_64bits(fasta.data(), fasta.size()), h2 = XXH3_64bits(file.data(), file.size());
      printf("S1FULL\t%s kernel\t%s\t%llu bases\t%.1f ms on the card (%.1f GB/s, %u windows of 1 MiB)\tXXH3 rebuilt %016llx file %016llx\tstatus %d\t%s\n", kern ? "classic" : "queue", argv[3], (unsigned long long)d.n, t * 1e3, d.n / t / 1e9, n,
             (unsigned long long)h1, (unsigned long long)h2, st, st == 0 && h1 == h2 && fasta.size() == file.size() ? "== FASTA" : "DIFFERS");
      fflush(stdout); if (st || h1 != h2) return 5; }
      cudaFree(dw); cudaFree(out); }
    // 100 000 windows against the CPU decode
    const uint32_t cnt[7] = {20000, 20000, 20000, 20000, 10000, 6000, 4000}; uint64_t total = 0, bad = 0; const int T = (int)std::thread::hardware_concurrency();
    for (int wi = 0; wi < 7; wi++) { const uint32_t W = WS[wi]; uint32_t left = cnt[wi], batch = 0; uint64_t badw = 0;
        while (left) { const size_t ai = batch % X.size(); const uint32_t n = std::min<uint32_t>(left, (uint32_t)std::max<uint64_t>(1, (256ull << 20) / W));
            const std::vector<uint64_t> o = rand_offs(D[ai].n, W, n, 7700 + wi * 1000 + batch); uint64_t* dw = upload(o); uint8_t* out; CK(cudaMalloc(&out, (size_t)n * W)); CK(cudaMemset(C.d_st, 0, 4));
            launch(C, D[ai], dw, n, W, 128, out); if (status(C)) badw += n;
            std::vector<uint8_t> h((size_t)n * W), hq((size_t)n * W); CK(cudaMemcpy(h.data(), out, h.size(), cudaMemcpyDeviceToHost));
            CK(cudaMemset(C.d_st, 0, 4)); CK(cudaMemset(out, 0, (size_t)n * W)); launch(C, D[ai], dw, n, W, 0, out); if (status(C)) badw += n;
            CK(cudaMemcpy(hq.data(), out, hq.size(), cudaMemcpyDeviceToHost)); cudaFree(dw); cudaFree(out);
            std::atomic<uint32_t> next{0}; std::atomic<uint64_t> nb{0}; std::vector<std::thread> th;
            for (int t = 0; t < T; t++) th.emplace_back([&] { std::vector<uint8_t> c(W + 64), blk(RR_BS), lit(RR_BS); std::vector<RrOp> ops(RR_MAXOPS);
                for (;;) { const uint32_t q = next.fetch_add(1); if (q >= n) break; if (!rr3_window(X[ai], C.R, o[q], W, c.data(), ops, blk.data(), lit.data()) || memcmp(c.data(), &h[(size_t)q * W], W) || memcmp(c.data(), &hq[(size_t)q * W], W)) nb++; } });
            for (auto& x : th) x.join(); badw += nb; left -= n; batch++; total += n; }
        bad += badw; printf("S1WIN\t%u\t%u windows\t%llu differ from the CPU decode (classic or queue kernel)\n", W, cnt[wi], (unsigned long long)badw); fflush(stdout); }
    printf("S1RESULT\t%llu windows over %zu assemblies\t%llu differ\t%s\n", (unsigned long long)total, X.size(), (unsigned long long)bad, bad ? "FAILED" : "ok");
    return bad ? 5 : 0;
}
// ---------------------------------------------------------------- S2
static int cmd_s2(char** argv) {
    Ctx C; ctx_init(C, argv[2]); Arch3 X = load3(argv[3]); Dev3 D = load_dev3(X); Fasta F = read_fasta(argv[4]);
    uint8_t* raw; CK(cudaMalloc(&raw, F.b.size())); CK(cudaMemcpy(raw, F.b.data(), F.b.size(), cudaMemcpyHostToDevice));
    for (uint32_t W : WS) { const uint32_t n = default_n(W); const int NB = 10; std::vector<uint64_t*> d(NB); for (int k = 0; k < NB; k++) d[k] = upload(rand_offs(D.n, W, n, 300 + k));
        uint8_t* out; CK(cudaMalloc(&out, (size_t)n * W)); raw_kernel<<<n, 256, 0, C.s>>>(raw, d[0], W, out); CK(cudaStreamSynchronize(C.s));
        double t0 = now_s(); for (int k = 0; k < NB; k++) raw_kernel<<<n, 256, 0, C.s>>>(raw, d[k], W, out); CK(cudaStreamSynchronize(C.s)); const double tr = now_s() - t0;
        int st; const double r3 = rate(C, D, W, n, 128, NB, 300, &st);
        printf("S2ROW\t%u\t%u\traw %.0f w/s %.2f GB/s\trefrel3 %.0f w/s %.2f GB/s\trefrel3/raw %.3f\t%s\n", W, n, n * NB / tr, (double)n * NB * W / tr / 1e9, r3, r3 * W / 1e9, r3 / (n * NB / tr), st ? "FAILED" : "ok");
        for (auto p : d) cudaFree(p); cudaFree(out); fflush(stdout); }
    { const size_t B = 1ull << 30; uint8_t *a, *b; CK(cudaMalloc(&a, B)); CK(cudaMalloc(&b, B)); CK(cudaMemcpyAsync(b, a, B, cudaMemcpyDeviceToDevice, C.s)); CK(cudaStreamSynchronize(C.s));
      const double t0 = now_s(); for (int k = 0; k < 10; k++) CK(cudaMemcpyAsync(b, a, B, cudaMemcpyDeviceToDevice, C.s)); CK(cudaStreamSynchronize(C.s)); const double t = now_s() - t0;
      printf("S2D2D\t1 GiB x 10\t%.1f GB/s copied (%.1f GB/s read + write)\n", 10.0 * B / t / 1e9, 20.0 * B / t / 1e9); }
    return 0;
}
// ---------------------------------------------------------------- S3
static int cmd_s3(char** argv) {
    Ctx C; ctx_init(C, argv[2]); Arch3 X = load3(argv[3]); Dev3 D = load_dev3(X); int st = 0, bad = 0;
    cudaDeviceProp pr; CK(cudaGetDeviceProperties(&pr, 0)); printf("[s3] %s, %d SMs, smem per block %zu B (dynamic %zu)\n", pr.name, pr.multiProcessorCount, (size_t)SMEM, (size_t)SMEM);
    for (uint32_t tpb : {32u, 64u, 128u, 256u}) { int nb = 0; CK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&nb, r3_kernel<false>, tpb, SMEM)); printf("S3OCC\t%u threads\t%d blocks per SM\t%d warps per SM\n", tpb, nb, nb * ((tpb + 31) / 32)); }
    for (uint32_t W : WS) { const uint32_t n = default_n(W); const double r = rate(C, D, W, n, 128, 10, 500, &st); bad |= st; printf("S3CURVE\t%u\t%u\t%.0f w/s\t%.2f GB/s\t%s\n", W, n, r, r * W / 1e9, st ? "FAILED" : "ok"); fflush(stdout); }
    for (uint32_t W : {256u, 4096u}) for (uint32_t n : {1024u, 4096u, 16384u, 65536u, 262144u}) for (uint32_t tpb : {32u, 64u, 128u, 256u}) {
        const double r = rate(C, D, W, n, tpb, 5, 900, &st); bad |= st; printf("S3GRID\tW %u\tn %u\ttpb %u\t%.0f w/s\t%.2f GB/s\t%s\n", W, n, tpb, r, r * W / 1e9, st ? "FAILED" : "ok"); fflush(stdout); }
    for (uint32_t W : {256u, 4096u, 65536u, 1048576u}) { const uint32_t n = default_n(W), bpw = bpw_of(W);
        const std::vector<uint64_t> o = rand_offs(D.n, W, n, 1234); uint64_t* dw = upload(o); uint8_t* out; CK(cudaMalloc(&out, (size_t)n * W));
        unsigned long long* prof; CK(cudaMalloc(&prof, (size_t)n * bpw * 16)); CK(cudaMemset(prof, 0, (size_t)n * bpw * 16)); CK(cudaMemset(C.d_st, 0, 4));
        launch(C, D, dw, n, W, 128, out, prof); st = status(C); bad |= st;
        std::vector<unsigned long long> h((size_t)n * bpw * 2); CK(cudaMemcpy(h.data(), prof, h.size() * 8, cudaMemcpyDeviceToHost));
        double dec = 0, cp = 0; uint64_t blocks = 0; for (size_t i = 0; i < h.size(); i += 2) if (h[i] || h[i + 1]) { dec += h[i]; cp += h[i + 1]; blocks++; }
        printf("S3PROF\tW %u\tn %u\t%llu blocks\tdecode (thread 0) %.0f cycles\tcopies + write %.0f cycles per block\tdecode share %.1f %%\n", W, n, (unsigned long long)blocks, dec / blocks, cp / blocks, 100.0 * dec / (dec + cp));
        cudaFree(dw); cudaFree(out); cudaFree(prof); fflush(stdout); }
    return bad ? 5 : 0;
}
static int cmd_curves(char** argv) {
    Ctx C; ctx_init(C, argv[2]); Arch3 X = load3(argv[3]); Dev3 D = load_dev3(X); Fasta F = read_fasta(argv[4]); int st = 0, bad = 0;
    uint8_t* raw; CK(cudaMalloc(&raw, F.b.size())); CK(cudaMemcpy(raw, F.b.data(), F.b.size(), cudaMemcpyHostToDevice));
    int ob = 0, oq = 0; CK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&ob, r3_kernel<false>, 128, SMEM)); CK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&oq, r3q_kernel, 32, QSMEM));
    cudaDeviceProp pr; CK(cudaGetDeviceProperties(&pr, 0));
    printf("OCC\t%u\tclassic: smem %zu B, %d blocks x 4 warps per SM\tqueue: smem %zu B, %d blocks x 1 warp per SM\t(%d SMs, %zu B smem per SM)\n", (unsigned)RR_BS, (size_t)SMEM, ob, (size_t)QSMEM, oq, pr.multiProcessorCount, (size_t)pr.sharedMemPerMultiprocessor);
    printf("[curves] RR_BS %u, payload %zu B, on the card %.2f MB\n", (unsigned)RR_BS, X.P.size(), D.bytes / 1e6);
    for (uint32_t W : WS) { const uint32_t n = default_n(W); const int NB = 10; std::vector<uint64_t*> d(NB); for (int k = 0; k < NB; k++) d[k] = upload(rand_offs(D.n, W, n, 500 + k));
        uint8_t* out; CK(cudaMalloc(&out, (size_t)n * W)); raw_kernel<<<n, 256, 0, C.s>>>(raw, d[0], W, out); CK(cudaStreamSynchronize(C.s));
        double t0 = now_s(); for (int k = 0; k < NB; k++) raw_kernel<<<n, 256, 0, C.s>>>(raw, d[k], W, out); CK(cudaStreamSynchronize(C.s)); const double rr = n * NB / (now_s() - t0);
        for (auto p : d) cudaFree(p); cudaFree(out);
        int s1 = 0, s2 = 0; const double rc = rate(C, D, W, n, 128, NB, 500, &s1), rq = rate(C, D, W, n, 0, NB, 500, &s2); bad |= s1 | s2;
        printf("CURVE\t%u\t%u\t%u\traw %.0f w/s %.2f GB/s\tclassic %.0f w/s %.2f GB/s (%.3f of raw)\tqueue %.0f w/s %.2f GB/s (%.3f of raw)\tqueue/classic %.2f\t%s\n", (unsigned)RR_BS, W, n,
               rr, rr * W / 1e9, rc, rc * W / 1e9, rc / rr, rq, rq * W / 1e9, rq / rr, rq / rc, (s1 | s2) ? "FAILED" : "ok"); fflush(stdout); }
    for (uint32_t W : {256u, 4096u}) for (uint32_t n : {1024u, 4096u, 16384u, 65536u, 262144u}) {
        const double r = rate(C, D, W, n, 0, 5, 900, &st); bad |= st; printf("QGRID\t%u\tW %u\tn %u\t%.0f w/s\t%.2f GB/s\t%s\n", (unsigned)RR_BS, W, n, r, r * W / 1e9, st ? "FAILED" : "ok"); fflush(stdout); }
    return bad ? 5 : 0;
}
static int cmd_one(char** argv) {
    Ctx C; ctx_init(C, argv[2]); Arch3 X = load3(argv[3]); Dev3 D = load_dev3(X); const uint32_t W = (uint32_t)atoi(argv[4]), n = (uint32_t)atoi(argv[5]), tpb = (uint32_t)atoi(argv[6]);
    uint64_t* dw = upload(rand_offs(D.n, W, n, 42)); uint8_t* out; CK(cudaMalloc(&out, (size_t)n * W)); CK(cudaMemset(C.d_st, 0, 4));
    launch(C, D, dw, n, W, tpb, out); const int st = status(C); printf("ONE\tW %u n %u tpb %u\tstatus %d\n", W, n, tpb, st); return st ? 5 : 0;
}
int main(int argc, char** argv) {
    for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
    if (argc >= 5 && !strcmp(argv[1], "s1")) return cmd_s1(argc, argv);
    if (argc >= 5 && !strcmp(argv[1], "s2")) return cmd_s2(argv);
    if (argc >= 5 && !strcmp(argv[1], "s3")) return cmd_s3(argv);
    if (argc >= 5 && !strcmp(argv[1], "curves")) return cmd_curves(argv);
    if (argc >= 7 && !strcmp(argv[1], "one")) return cmd_one(argv);
    printf("usage: refrel3_gpu s1 <ref.fa> <prefix> <asm.fa> [...] | s2|s3|curves <ref.fa> <prefix> <asm.fa> | one <ref.fa> <prefix> <W> <n> <tpb>\n");
    return 1;
}
