// refrel3_gpu.cu - refrel3 windows on the GPU (research; format refrel3.h). The T2T reference resident decoded; per
// assembly the refrel3 payload (one rANS stream per 16 KiB block), the block offsets, the carried block states and the
// static tables resident. No host selection: the grid is (window x blocks per window); a CUDA block takes its refrel3
// block from the window's start, thread 0 decodes the block's stream into ops (r3_decode_block, the code the CPU tool
// runs), the threads execute literal / reference / reverse-complement copies in parallel, one warp the self copies in
// order, and the window's part is written. Against: the same assembly's open archive through the library's windows
// call (FASTA bytes) on the same card.
//   refrel3_gpu curves <ref.fa> <dir/name> <asm.fa> <asm.open.aet>
//   refrel3_gpu capacity <ref.fa> <dir/name>...
// Build: nvcc -std=c++17 -O3 -arch=sm_XX -Isrc -Iresearch/refrel research/refrel/refrel3_gpu.cu src/aceapex_api.cpp -L. -laceapex_gpu -lzstd -lpthread
#define RR3_NO_MAIN
#include "refrel3.cpp"
#include "aceapex_gpu.h"
#include <cuda_runtime.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { printf("CUDA %s @%d: %s\n", #x, __LINE__, cudaGetErrorString(e_)); exit(2); } } while (0)
static const uint32_t KOPS = 1024;
static const size_t SMEM = KOPS * sizeof(RrOp) + 2 * RR_BS;

struct Dev3 { uint8_t* P = nullptr; uint64_t* off = nullptr; R3Diag* st = nullptr; R3Tab* T = nullptr; uint64_t n = 0, nb = 0, bytes = 0, payload = 0; };
static Dev3 load_dev3(const std::string& nm) {
    Arch3 X = load3(nm); Dev3 D; D.n = X.M.n; D.nb = X.M.nb;
    if (!X.M.low.empty()) { printf("%s: lower-case runs present - not handled on the card in this tool\n", nm.c_str()); exit(3); }
    CK(cudaMalloc(&D.P, X.P.size() + 64)); CK(cudaMemcpy(D.P, X.P.data(), X.P.size(), cudaMemcpyHostToDevice));
    CK(cudaMalloc(&D.off, X.off.size() * 8)); CK(cudaMemcpy(D.off, X.off.data(), X.off.size() * 8, cudaMemcpyHostToDevice));
    CK(cudaMalloc(&D.st, X.st.size() * sizeof(R3Diag))); CK(cudaMemcpy(D.st, X.st.data(), X.st.size() * sizeof(R3Diag), cudaMemcpyHostToDevice));
    CK(cudaMalloc(&D.T, sizeof(R3Tab))); CK(cudaMemcpy(D.T, X.T, sizeof(R3Tab), cudaMemcpyHostToDevice));
    D.payload = X.P.size(); D.bytes = X.P.size() + X.off.size() * 8 + X.st.size() * sizeof(R3Diag) + sizeof(R3Tab); delete X.T;
    return D;
}

__global__ void r3_kernel(const uint8_t* __restrict__ P, const uint64_t* __restrict__ off, const R3Diag* __restrict__ st, const R3Tab* __restrict__ T,
                          const uint8_t* __restrict__ ref, uint64_t ref_n, uint64_t n_bases, const uint64_t* __restrict__ woff, uint32_t W, uint32_t bpw,
                          uint8_t* __restrict__ out, int* status) {
    extern __shared__ __align__(16) uint8_t sm[];
    RrOp* ops = (RrOp*)sm; uint8_t* blk = sm + KOPS * sizeof(RrOp); uint8_t* lit = blk + RR_BS; __shared__ int nk;
    const uint32_t w = blockIdx.x / bpw, j = blockIdx.x % bpw; const uint64_t s = woff[w];
    const uint64_t b0 = s / RR_BS, b1 = (s + W - 1) / RR_BS, b = b0 + j; if (b > b1) return;
    const uint64_t bst = b * RR_BS; const uint32_t blen = (uint32_t)min((uint64_t)RR_BS, n_bases - bst);
    if (threadIdx.x == 0) nk = r3_decode_block(P + off[b], (uint32_t)(off[b + 1] - off[b]), T, ref, ref_n, blen, st[b], ops, KOPS, lit, RR_BS);
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
}

static std::vector<uint8_t> upload_ref(const char* fa, uint8_t** d_ref) {
    Fasta RF = read_fasta(fa); std::vector<uint8_t> R = upper(RF.b);
    CK(cudaMalloc(d_ref, R.size())); CK(cudaMemcpy(*d_ref, R.data(), R.size(), cudaMemcpyHostToDevice)); return R;
}

static int cmd_curves(char** argv) {
    uint8_t* d_ref; const std::vector<uint8_t> R = upload_ref(argv[2], &d_ref);
    Dev3 D = load_dev3(argv[3]); Fasta F = read_fasta(argv[4]);
    if (F.b.size() != D.n) { printf("base count differs\n"); return 2; }
    std::vector<uint8_t> open = slurp(argv[5]); aceapex_gpu_plan* po = aceapex_gpu_plan_create(open.data(), open.size(), 0); if (!po) { printf("open plan failed\n"); return 3; }
    const uint64_t orig_o = aceapex_gpu_output_bytes(po); uint8_t* d_open; CK(cudaMalloc(&d_open, open.size())); CK(cudaMemcpy(d_open, open.data(), open.size(), cudaMemcpyHostToDevice));
    CK(cudaFuncSetAttribute(r3_kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, (int)SMEM));
    cudaDeviceProp pr; CK(cudaGetDeviceProperties(&pr, 0));
    printf("[gpu3] %s | reference %.2f GB resident | refrel3 %s: payload %.2f MB, on the card %.2f MB (offsets, states, tables) | open %.2f MB\n", pr.name, R.size() / 1e9, argv[3], D.payload / 1e6, D.bytes / 1e6, open.size() / 1e6);
    cudaStream_t s; CK(cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking)); int* d_st; CK(cudaMalloc(&d_st, 4));
    for (uint32_t W = 256; W <= (1u << 20); W *= 4) {
        const uint32_t n = (uint32_t)std::min<uint64_t>(65536, std::max<uint64_t>(64, (1ull << 29) / W)); const int NB = 10; const uint32_t bpw = (W + RR_BS - 1) / RR_BS + 1;
        std::mt19937_64 g(20261003 + W); std::vector<uint64_t*> d_off(NB), d_oo(NB); std::vector<std::vector<uint64_t>> offs(NB, std::vector<uint64_t>(n)), offo(NB, std::vector<uint64_t>(n));
        for (int k = 0; k < NB; k++) { for (uint32_t i = 0; i < n; i++) { offs[k][i] = g() % (D.n - W + 1); offo[k][i] = g() % (orig_o - W + 1); }
            CK(cudaMalloc(&d_off[k], n * 8)); CK(cudaMemcpy(d_off[k], offs[k].data(), n * 8, cudaMemcpyHostToDevice)); CK(cudaMalloc(&d_oo[k], n * 8)); CK(cudaMemcpy(d_oo[k], offo[k].data(), n * 8, cudaMemcpyHostToDevice)); }
        uint8_t* d_out; CK(cudaMalloc(&d_out, (size_t)n * W)); CK(cudaMemset(d_st, 0, 4));
        auto launch = [&](int k) { r3_kernel<<<n * bpw, 128, SMEM, s>>>(D.P, D.off, D.st, D.T, d_ref, R.size(), D.n, d_off[k], W, bpw, d_out, d_st); };
        launch(0); CK(cudaStreamSynchronize(s)); CK(cudaGetLastError());
        double t0 = now_s(); for (int k = 0; k < NB; k++) launch(k); CK(cudaStreamSynchronize(s)); const double tr = now_s() - t0;
        int st_h = -1; CK(cudaMemcpy(&st_h, d_st, 4, cudaMemcpyDeviceToHost)); bool ok = st_h == 0;
        { std::vector<uint8_t> h(W); const uint32_t step = std::max<uint32_t>(1, n / 64);
          for (uint32_t i = 0; i < n && ok; i += step) { CK(cudaMemcpy(h.data(), d_out + (uint64_t)i * W, W, cudaMemcpyDeviceToHost)); if (memcmp(h.data(), &F.b[offs[NB - 1][i]], W)) ok = false; } }
        printf("R3GWIN\trefrel3\t%u\t%u\t%.0f\t%.3f\t%s\n", W, n, (double)n * NB / tr, (double)n * NB * W / tr / 1e9, ok ? "ok" : "FAILED");
        uint8_t *d_oout, *d_otmp; int* d_ost; CK(cudaMalloc(&d_oout, (size_t)n * W)); CK(cudaMalloc(&d_otmp, aceapex_gpu_windows_temp_bytes(po, n, W))); CK(cudaMalloc(&d_ost, 4)); CK(cudaMemset(d_ost, 0, 4));
        aceapex_gpu_decompress_windows_async(po, d_open, d_oo[0], n, W, d_oout, d_otmp, d_ost, s); CK(cudaStreamSynchronize(s));
        t0 = now_s(); for (int k = 0; k < NB; k++) aceapex_gpu_decompress_windows_async(po, d_open, d_oo[k], n, W, d_oout, d_otmp, d_ost, s); CK(cudaStreamSynchronize(s)); const double to_ = now_s() - t0;
        int ost = -1; CK(cudaMemcpy(&ost, d_ost, 4, cudaMemcpyDeviceToHost));
        printf("R3GWIN\topen\t%u\t%u\t%.0f\t%.3f\t%s\n", W, n, (double)n * NB / to_, (double)n * NB * W / to_ / 1e9, ost == 0 ? "ok" : "FAILED");
        for (int k = 0; k < NB; k++) { cudaFree(d_off[k]); cudaFree(d_oo[k]); } cudaFree(d_out); cudaFree(d_oout); cudaFree(d_otmp); cudaFree(d_ost); fflush(stdout);
    }
    return 0;
}
static int cmd_capacity(int argc, char** argv) {
    size_t f0, tot; CK(cudaMemGetInfo(&f0, &tot)); uint8_t* d_ref; const std::vector<uint8_t> R = upload_ref(argv[2], &d_ref);
    size_t f1; CK(cudaMemGetInfo(&f1, &tot)); uint64_t sum = 0; int n = 0;
    for (int a = 3; a < argc; a++) { Dev3 D = load_dev3(argv[a]); sum += D.bytes; n++; printf("[cap3] %s: %.2f MB on the card\n", argv[a], D.bytes / 1e6); }
    size_t f2; CK(cudaMemGetInfo(&f2, &tot));
    printf("[cap3] card %.1f GiB; reference %.3f GB (free %.2f -> %.2f GiB); %d assemblies %.2f MB (free -> %.2f GiB)\n", tot / 1073741824.0, R.size() / 1e9, f0 / 1073741824.0, f1 / 1073741824.0, n, sum / 1e6, f2 / 1073741824.0);
    const double mean = n ? (double)sum / n : 0;
    for (double cap : {80.0, 96.0}) printf("CAP3ROW\t%.0f\t%.3f\t%.3f\t%.0f\n", cap, R.size() / 1e9, mean / 1e6, (cap * 1073741824.0 - R.size() - 2.0 * 1073741824.0) / mean);
    return 0;
}
int main(int argc, char** argv) {
    for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
    if (argc >= 6 && !strcmp(argv[1], "curves")) return cmd_curves(argv);
    if (argc >= 4 && !strcmp(argv[1], "capacity")) return cmd_capacity(argc, argv);
    printf("usage: refrel3_gpu curves <ref.fa> <dir/name> <asm.fa> <asm.open.aet> | capacity <ref.fa> <dir/name>...\n");
    return 1;
}
