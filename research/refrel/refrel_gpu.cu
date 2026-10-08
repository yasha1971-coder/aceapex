// refrel_gpu.cu - refrel windows on the GPU (research; format refrel_format.h). The T2T reference is resident decoded
// (upper-case bases); per assembly the token stream and the literal stream are resident as ACEAPEX open archives and
// decoded on the device by the library's windows call (libaceapex_gpu: one window per requested window, covering the
// tokens / literals of its blocks); then one CUDA block per (window, refrel block): thread 0 turns the tokens into ops
// (rr_parse, the code the CPU tool uses), the threads execute literal / reference / reverse-complement copies in
// parallel, one warp the self copies in order, and the window's part of the block is written out.
// Against: the same assembly's open archive through the library's windows call (FASTA bytes) on the same card.
//
//   refrel_gpu curves <ref.fa> <dir/name> <asm.fa> <asm.open.aet>   GB/s and windows/s for W = 256 B .. 1 MiB, both
//   refrel_gpu one <ref.fa> <dir/name> <asm.open.aet> <W> <n>        one batch of each (for ncu)
//   refrel_gpu capacity <ref.fa> <dir/name>...                       reference + assemblies resident: bytes, free memory
// Build: nvcc -std=c++17 -O3 -arch=sm_XX -Isrc -Iresearch/refrel research/refrel/refrel_gpu.cu -L. -laceapex_gpu -lzstd
#include "aceapex_gpu.h"
#include "refrel_io.h"
#include <cuda_runtime.h>
#include <algorithm>
#include <chrono>
#include <random>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { printf("CUDA %s @%d: %s\n", #x, __LINE__, cudaGetErrorString(e_)); exit(2); } } while (0)
static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static const uint32_t KOPS = 1024;                                       // max ops per block on the card (HPRC: 686-748)

struct Dev {                                                             // one assembly on the card
    Meta M; aceapex_gpu_plan *pt = nullptr, *pl = nullptr; uint8_t *tok = nullptr, *lit = nullptr; uint32_t *to = nullptr, *lo = nullptr;
    uint64_t tok_n = 0, lit_n = 0, bytes = 0, tok_b = 0, lit_b = 0;
};
static Dev load_dev(const std::string& nm) {
    Dev D; D.M = load_meta(nm + ".meta.zst");
    if (!D.M.low.empty()) { printf("%s: lower-case runs present - not handled on the card in this tool\n", nm.c_str()); exit(3); }
    std::vector<uint8_t> t = slurp(nm + ".tok.aet"), l = slurp(nm + ".lit.aet");
    D.pt = aceapex_gpu_plan_create(t.data(), t.size(), 0); D.pl = aceapex_gpu_plan_create(l.data(), l.size(), 0);
    if (!D.pt || !D.pl) { printf("plan_create failed: %d\n", aceapex_gpu_last_error()); exit(3); }
    D.tok_n = aceapex_gpu_output_bytes(D.pt); D.lit_n = aceapex_gpu_output_bytes(D.pl);
    if (D.tok_n != D.M.to[D.M.nb] || D.lit_n != D.M.lo[D.M.nb]) { printf("stream sizes differ from the meta\n"); exit(3); }
    CK(cudaMalloc(&D.tok, t.size())); CK(cudaMemcpy(D.tok, t.data(), t.size(), cudaMemcpyHostToDevice));
    CK(cudaMalloc(&D.lit, l.size())); CK(cudaMemcpy(D.lit, l.data(), l.size(), cudaMemcpyHostToDevice));
    std::vector<uint32_t> to(D.M.to.begin(), D.M.to.end()), lo(D.M.lo.begin(), D.M.lo.end());
    CK(cudaMalloc(&D.to, to.size() * 4)); CK(cudaMemcpy(D.to, to.data(), to.size() * 4, cudaMemcpyHostToDevice));
    CK(cudaMalloc(&D.lo, lo.size() * 4)); CK(cudaMemcpy(D.lo, lo.data(), lo.size() * 4, cudaMemcpyHostToDevice));
    D.tok_b = t.size(); D.lit_b = l.size(); D.bytes = t.size() + l.size() + to.size() * 4 + lo.size() * 4;
    return D;
}

struct Win { uint64_t s; uint32_t b0, sh_t, sh_l; };                    // window start, first block, shifts inside the slots
__global__ void rr_kernel(const uint8_t* __restrict__ ref, uint64_t ref_n, uint64_t n_bases, const uint32_t* __restrict__ to, const uint32_t* __restrict__ lo,
                          const uint8_t* __restrict__ tw, uint32_t ws_t, const uint8_t* __restrict__ lw, uint32_t ws_l,
                          const Win* __restrict__ win, const uint2* __restrict__ pairs, uint32_t W, uint8_t* __restrict__ out, int* status) {
    __shared__ RrOp ops[KOPS]; __shared__ uint8_t blk[RR_BS]; __shared__ int nk;
    const uint2 pr = pairs[blockIdx.x]; const uint32_t w = pr.x, b = pr.y; const Win wd = win[w];
    const uint64_t bst = (uint64_t)b * RR_BS; const uint32_t blen = (uint32_t)min((uint64_t)RR_BS, n_bases - bst);
    const uint8_t* tk = tw + (uint64_t)w * ws_t + wd.sh_t + (to[b] - to[wd.b0]);
    const uint8_t* lt = lw + (uint64_t)w * ws_l + wd.sh_l + (lo[b] - lo[wd.b0]);
    if (threadIdx.x == 0) nk = rr_parse(tk, to[b + 1] - to[b], lo[b + 1] - lo[b], ref_n, blen, ops, KOPS);
    __syncthreads();
    const int k = nk; if (k < 0) { if (threadIdx.x == 0) atomicOr(status, 1); return; }
    for (int q = 0; q < k; q++) { const RrOp op = ops[q];                // literal, reference, reverse complement: in parallel
        if (op.kind == 0) for (uint32_t j = threadIdx.x; j < op.len; j += blockDim.x) blk[op.dst + j] = lt[op.src + j];
        else if (op.kind == 1) for (uint32_t j = threadIdx.x; j < op.len; j += blockDim.x) blk[op.dst + j] = ref[op.src + j];
        else if (op.kind == 3) for (uint32_t j = threadIdx.x; j < op.len; j += blockDim.x) blk[op.dst + j] = rr_comp(ref[op.src + op.len - 1 - j]); }
    __syncthreads();
    if (threadIdx.x < 32) for (int q = 0; q < k; q++) { const RrOp op = ops[q]; if (op.kind != 2) continue;   // self copies, in order
        const uint32_t dist = op.dst - (uint32_t)op.src;
        for (uint32_t c = 0; c < op.len;) { const uint32_t step = min(dist, op.len - c);
            for (uint32_t j = threadIdx.x; j < step; j += 32) blk[op.dst + c + j] = blk[op.src + c + j];
            __syncwarp(); c += step; } }
    __syncthreads();
    const uint64_t a = max(wd.s, bst), e = min(wd.s + W, bst + blen);
    for (uint64_t x = a + threadIdx.x; x < e; x += blockDim.x) out[(uint64_t)w * W + (x - wd.s)] = blk[x - bst];
}

struct Batch {                                                           // device buffers for n windows of W bases
    uint64_t *d_ot = nullptr, *d_ol = nullptr; uint8_t *d_tw = nullptr, *d_lw = nullptr, *d_tt = nullptr, *d_tl = nullptr, *d_out = nullptr; Win* d_win = nullptr; uint2* d_pairs = nullptr; int* d_st = nullptr;
    size_t cap_tw = 0, cap_lw = 0, cap_tt = 0, cap_tl = 0, cap_pairs = 0, cap_out = 0; uint32_t n = 0, W = 0;
};
static void grow(uint8_t** p, size_t* cap, size_t need) { if (need > *cap) { if (*p) cudaFree(*p); CK(cudaMalloc(p, need)); *cap = need; } }
// one batch: host selection (spans), two library windows calls, the kernel; returns host-side seconds
static double rr_batch(const Dev& D, const uint8_t* d_ref, uint64_t ref_n, Batch& B, const std::vector<uint64_t>& off, uint32_t W, cudaStream_t s) {
    const double t0 = now_s(); const uint32_t n = (uint32_t)off.size();
    std::vector<Win> wv(n); std::vector<uint2> pairs; std::vector<uint64_t> ot(n), ol(n); uint32_t ws_t = 1, ws_l = 1;
    for (uint32_t i = 0; i < n; i++) { const uint64_t b0 = off[i] / RR_BS, b1 = (off[i] + W - 1) / RR_BS;
        ws_t = std::max<uint32_t>(ws_t, D.M.to[b1 + 1] - D.M.to[b0]); ws_l = std::max<uint32_t>(ws_l, D.M.lo[b1 + 1] - D.M.lo[b0]);
        for (uint64_t b = b0; b <= b1; b++) pairs.push_back(make_uint2(i, (uint32_t)b)); wv[i].s = off[i]; wv[i].b0 = (uint32_t)b0; }
    for (uint32_t i = 0; i < n; i++) { const uint64_t b0 = wv[i].b0, t = D.M.to[b0], l = D.M.lo[b0];
        ot[i] = std::min<uint64_t>(t, D.tok_n - ws_t); ol[i] = std::min<uint64_t>(l, D.lit_n - ws_l); wv[i].sh_t = (uint32_t)(t - ot[i]); wv[i].sh_l = (uint32_t)(l - ol[i]); }
    const double t1 = now_s();
    if (B.n < n) { if (B.d_ot) { cudaFree(B.d_ot); cudaFree(B.d_ol); cudaFree(B.d_win); } CK(cudaMalloc(&B.d_ot, n * 8)); CK(cudaMalloc(&B.d_ol, n * 8)); CK(cudaMalloc(&B.d_win, n * sizeof(Win))); B.n = n; }
    if (!B.d_st) CK(cudaMalloc(&B.d_st, 4));
    size_t pc = B.d_pairs ? B.cap_pairs : 0; if (pairs.size() * sizeof(uint2) > pc) { if (B.d_pairs) cudaFree(B.d_pairs); CK(cudaMalloc(&B.d_pairs, pairs.size() * sizeof(uint2))); B.cap_pairs = pairs.size() * sizeof(uint2); }
    grow(&B.d_tw, &B.cap_tw, (size_t)n * ws_t + 64); grow(&B.d_lw, &B.cap_lw, (size_t)n * ws_l + 64);
    grow(&B.d_tt, &B.cap_tt, aceapex_gpu_windows_temp_bytes(D.pt, n, ws_t)); grow(&B.d_tl, &B.cap_tl, aceapex_gpu_windows_temp_bytes(D.pl, n, ws_l));
    grow(&B.d_out, &B.cap_out, (size_t)n * W);
    CK(cudaMemcpyAsync(B.d_ot, ot.data(), n * 8, cudaMemcpyHostToDevice, s)); CK(cudaMemcpyAsync(B.d_ol, ol.data(), n * 8, cudaMemcpyHostToDevice, s));
    CK(cudaMemcpyAsync(B.d_win, wv.data(), n * sizeof(Win), cudaMemcpyHostToDevice, s)); CK(cudaMemcpyAsync(B.d_pairs, pairs.data(), pairs.size() * sizeof(uint2), cudaMemcpyHostToDevice, s));
    if (aceapex_gpu_decompress_windows_async(D.pt, D.tok, B.d_ot, n, ws_t, B.d_tw, B.d_tt, B.d_st, s) || aceapex_gpu_decompress_windows_async(D.pl, D.lit, B.d_ol, n, ws_l, B.d_lw, B.d_tl, B.d_st, s)) { printf("windows call failed\n"); exit(4); }
    rr_kernel<<<(unsigned)pairs.size(), 128, 0, s>>>(d_ref, ref_n, D.M.n, D.to, D.lo, B.d_tw, ws_t, B.d_lw, ws_l, B.d_win, B.d_pairs, W, B.d_out, B.d_st);
    CK(cudaGetLastError());
    return t1 - t0;
}

static std::vector<uint8_t> upload_ref(const char* fa, uint8_t** d_ref) {
    Fasta RF = read_fasta(fa); std::vector<uint8_t> R = upper(RF.b);
    CK(cudaMalloc(d_ref, R.size())); CK(cudaMemcpy(*d_ref, R.data(), R.size(), cudaMemcpyHostToDevice)); return R;
}

static int cmd_curves(char** argv, bool one) {
    uint8_t* d_ref; const std::vector<uint8_t> R = upload_ref(argv[2], &d_ref); const uint64_t Rn = R.size();
    Dev D = load_dev(argv[3]);
    Fasta F; if (!one) F = read_fasta(argv[4]);
    std::vector<uint8_t> open = slurp(one ? argv[4] : argv[5]);
    aceapex_gpu_plan* po = aceapex_gpu_plan_create(open.data(), open.size(), 0); if (!po) { printf("open plan failed\n"); return 3; }
    const uint64_t orig_o = aceapex_gpu_output_bytes(po); uint8_t* d_open; CK(cudaMalloc(&d_open, open.size())); CK(cudaMemcpy(d_open, open.data(), open.size(), cudaMemcpyHostToDevice));
    cudaDeviceProp pr; CK(cudaGetDeviceProperties(&pr, 0));
    printf("[gpu] %s | reference %.2f GB resident | refrel %s: token archive %.2f MB + literal archive %.2f MB + block spans %.2f MB | open %.2f MB\n", pr.name, Rn / 1e9, argv[3],
           D.tok_b / 1e6, D.lit_b / 1e6, (D.M.nb + 1) * 8 / 1e6, open.size() / 1e6);
    cudaStream_t s; CK(cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking)); Batch B; int st_h = 0;
    std::vector<uint32_t> Ws; if (one) Ws.push_back((uint32_t)atoi(argv[5])); else for (uint32_t W = 256; W <= (1u << 20); W *= 4) Ws.push_back(W);
    for (uint32_t W : Ws) {
        const uint32_t n = one ? (uint32_t)atoi(argv[6]) : (uint32_t)std::min<uint64_t>(65536, std::max<uint64_t>(64, (1ull << 29) / W));
        std::mt19937_64 g(20261003 + W); const int NB = one ? 1 : 10;
        std::vector<std::vector<uint64_t>> offs(NB, std::vector<uint64_t>(n)), offo(NB, std::vector<uint64_t>(n));
        for (int k = 0; k < NB; k++) for (uint32_t i = 0; i < n; i++) { offs[k][i] = g() % (D.M.n - W + 1); offo[k][i] = g() % (orig_o - W + 1); }
        // refrel
        double host = 0; if (!one) { rr_batch(D, d_ref, Rn, B, offs[0], W, s); CK(cudaStreamSynchronize(s)); }
        CK(cudaMemsetAsync(B.d_st, 0, 4, s));
        double t0 = now_s(); for (int k = 0; k < NB; k++) host += rr_batch(D, d_ref, Rn, B, offs[k], W, s); CK(cudaStreamSynchronize(s)); double tr = now_s() - t0;
        CK(cudaMemcpy(&st_h, B.d_st, 4, cudaMemcpyDeviceToHost));
        bool ok = st_h == 0;
        if (!one) { std::vector<uint8_t> h((size_t)W); const uint32_t step = std::max<uint32_t>(1, n / 64);   // last batch, 64 windows checked
            for (uint32_t i = 0; i < n && ok; i += step) { CK(cudaMemcpy(h.data(), B.d_out + (uint64_t)i * W, W, cudaMemcpyDeviceToHost)); if (memcmp(h.data(), &F.b[offs[NB - 1][i]], W)) ok = false; } }
        printf("RGWIN\trefrel\t%u\t%u\t%.0f\t%.3f\t%.1f\t%s\n", W, n, (double)n * NB / tr, (double)n * NB * W / tr / 1e9, host / NB * 1e6, ok ? "ok" : "FAILED");
        // open (FASTA bytes, the library's windows call)
        uint64_t* d_oo; uint8_t *d_oout, *d_otmp; int* d_ost; CK(cudaMalloc(&d_oo, (size_t)n * 8)); CK(cudaMalloc(&d_oout, (size_t)n * W)); CK(cudaMalloc(&d_otmp, aceapex_gpu_windows_temp_bytes(po, n, W))); CK(cudaMalloc(&d_ost, 4)); CK(cudaMemset(d_ost, 0, 4));
        std::vector<uint64_t*> d_oos(NB); for (int k = 0; k < NB; k++) { CK(cudaMalloc(&d_oos[k], (size_t)n * 8)); CK(cudaMemcpy(d_oos[k], offo[k].data(), (size_t)n * 8, cudaMemcpyHostToDevice)); }
        if (!one) { aceapex_gpu_decompress_windows_async(po, d_open, d_oos[0], n, W, d_oout, d_otmp, d_ost, s); CK(cudaStreamSynchronize(s)); }
        t0 = now_s(); for (int k = 0; k < NB; k++) aceapex_gpu_decompress_windows_async(po, d_open, d_oos[k], n, W, d_oout, d_otmp, d_ost, s); CK(cudaStreamSynchronize(s)); const double to_ = now_s() - t0;
        int ost = -1; CK(cudaMemcpy(&ost, d_ost, 4, cudaMemcpyDeviceToHost)); bool ok2 = ost == 0;
        if (!one) { std::vector<uint8_t> h((size_t)W); std::vector<uint8_t> fa; const uint32_t step = std::max<uint32_t>(1, n / 64);
            FILE* f = fopen(argv[4], "rb"); for (uint32_t i = 0; i < n && ok2; i += step) { CK(cudaMemcpy(h.data(), d_oout + (uint64_t)i * W, W, cudaMemcpyDeviceToHost)); fa.resize(W);
                fseek(f, (long)offo[NB - 1][i], SEEK_SET); if (fread(fa.data(), 1, W, f) != W || memcmp(fa.data(), h.data(), W)) ok2 = false; } fclose(f); }
        printf("RGWIN\topen\t%u\t%u\t%.0f\t%.3f\t-\t%s\n", W, n, (double)n * NB / to_, (double)n * NB * W / to_ / 1e9, ok2 ? "ok" : "FAILED");
        for (auto p : d_oos) cudaFree(p); cudaFree(d_oo); cudaFree(d_oout); cudaFree(d_otmp); cudaFree(d_ost); fflush(stdout);
    }
    return 0;
}

static int cmd_capacity(int argc, char** argv) {
    size_t f0, tot; CK(cudaMemGetInfo(&f0, &tot)); uint8_t* d_ref; const std::vector<uint8_t> R = upload_ref(argv[2], &d_ref);
    size_t f1; CK(cudaMemGetInfo(&f1, &tot)); uint64_t sum = 0; int n = 0;
    for (int a = 3; a < argc; a++) { Dev D = load_dev(argv[a]); sum += D.bytes; n++; printf("[cap] %s: %.2f MB on the card (token + literal archives, block spans)\n", argv[a], D.bytes / 1e6); }
    size_t f2; CK(cudaMemGetInfo(&f2, &tot));
    printf("[cap] card %.1f GiB; reference %.3f GB resident (free %.2f -> %.2f GiB); %d assemblies %.2f MB (free -> %.2f GiB)\n", tot / 1073741824.0, R.size() / 1e9, f0 / 1073741824.0, f1 / 1073741824.0, n, sum / 1e6, f2 / 1073741824.0);
    const double mean = n ? (double)sum / n : 0;
    for (double cap : {80.0, 96.0}) printf("CAPROW\t%.0f\t%.3f\t%.3f\t%.0f\n", cap, R.size() / 1e9, mean / 1e6, (cap * 1073741824.0 - R.size() - 2.0 * 1073741824.0) / mean);
    return 0;
}

int main(int argc, char** argv) {
    if (argc >= 6 && !strcmp(argv[1], "curves")) return cmd_curves(argv, false);
    if (argc >= 7 && !strcmp(argv[1], "one")) return cmd_curves(argv, true);
    if (argc >= 4 && !strcmp(argv[1], "capacity")) return cmd_capacity(argc, argv);
    printf("usage: refrel_gpu curves <ref.fa> <dir/name> <asm.fa> <asm.open.aet> | one <ref.fa> <dir/name> <asm.open.aet> <W> <n> | capacity <ref.fa> <dir/name>...\n");
    return 1;
}
