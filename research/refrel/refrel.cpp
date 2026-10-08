// refrel.cpp - research: HPRC assemblies as LZ77 against the decoded T2T reference (format: refrel_format.h).
// No ACEPX2 change: the token stream and the literal stream of an assembly are written raw and compressed by the
// ACEAPEX CLI in the open profile (run_cpu.sh), so the literals are coded exactly as in open; the decoder reads them
// back with aceapex_decompress_region (src/ linked as a library, not modified).
//
//   refrel build <ref.fa> <out_dir> <threads> <asm.fa>...   reference index once, then per assembly: <name>.tok, .lit (raw
//                                                           streams for the CLI), <name>.meta.zst (records, case runs,
//                                                           per-block spans); parse time and copy statistics
//   refrel full <ref.fa> <dir/name> <out.fa>                all blocks from <name>.tok.aet / .lit.aet -> FASTA (cmp it)
//   refrel windows <ref.fa> <dir/name> <asm.fa> <asm.open.aet> <threads> [seed]
//                                                           random windows of W = 256 B .. 1 MiB bases: refrel and the
//                                                           open archive of the same assembly, every window == FASTA
// Windows are in base coordinates of the assembly (records concatenated, no headers or line ends, case kept).
// Build: g++ -std=c++17 -O3 -march=native -funroll-loops -Isrc research/refrel/refrel.cpp src/aceapex_api.cpp -lzstd -lpthread
#include "aceapex.h"
#include "refrel_io.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <thread>
#include <vector>

static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
// ---------------------------------------------------------------- reference index: 32-mers at every 8th position
static const int K = 32, STRIDE = 8, HB = 26;
static inline int code2(uint8_t c) { switch (c) { case 'A': return 0; case 'C': return 1; case 'G': return 2; case 'T': return 3; default: return -1; } }
static inline bool kmer(const uint8_t* p, uint64_t* k) { uint64_t x = 0; for (int j = 0; j < K; j++) { int c = code2(p[j]); if (c < 0) return false; x = (x << 2) | (uint64_t)c; } *k = x; return true; }
static inline uint64_t mix(uint64_t x) { x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33; x *= 0xc4ceb9fe1a85ec53ULL; x ^= x >> 33; return x; }
struct Index { std::vector<uint32_t> off, pos; };
static Index build_index(const std::vector<uint8_t>& R, int T) {
    Index I; const uint64_t NB = 1ull << HB; I.off.assign(NB + 1, 0); std::vector<std::atomic<uint32_t>> cnt(NB);
    for (auto& c : cnt) c.store(0, std::memory_order_relaxed);
    const uint64_t n = R.size() >= (size_t)K ? (R.size() - K) / STRIDE + 1 : 0;
    auto run = [&](auto&& f) { std::vector<std::thread> th; for (int t = 0; t < T; t++) th.emplace_back([&, t] { for (uint64_t s = t; s < n; s += T) f(s * STRIDE); }); for (auto& x : th) x.join(); };
    run([&](uint64_t p) { uint64_t k; if (kmer(&R[p], &k)) cnt[mix(k) >> (64 - HB)].fetch_add(1, std::memory_order_relaxed); });
    uint64_t acc = 0; for (uint64_t b = 0; b < NB; b++) { I.off[b] = (uint32_t)acc; acc += cnt[b].load(); cnt[b].store(0); } I.off[NB] = (uint32_t)acc;
    I.pos.resize(acc);
    run([&](uint64_t p) { uint64_t k; if (kmer(&R[p], &k)) { const uint64_t b = mix(k) >> (64 - HB); I.pos[I.off[b] + cnt[b].fetch_add(1, std::memory_order_relaxed)] = (uint32_t)p; } });
    std::vector<std::thread> th; for (int t = 0; t < T; t++) th.emplace_back([&, t] { for (uint64_t b = t; b < NB; b += T) std::sort(I.pos.begin() + I.off[b], I.pos.begin() + I.off[b + 1]); }); for (auto& x : th) x.join();
    return I;
}

// ---------------------------------------------------------------- encoder
static inline uint32_t lcp(const uint8_t* a, const uint8_t* b, uint64_t n) { uint64_t i = 0;
    while (i + 8 <= n) { uint64_t x, y; memcpy(&x, a + i, 8); memcpy(&y, b + i, 8); if (x != y) return (uint32_t)(i + (__builtin_ctzll(x ^ y) >> 3)); i += 8; }
    while (i < n && a[i] == b[i]) i++; return (uint32_t)i; }
static inline size_t leb_len(uint64_t v) { size_t n = 1; while (v >= 0x80) { v >>= 7; n++; } return n; }
static inline void put_leb(std::vector<uint8_t>& o, uint64_t v) { while (v >= 0x80) { o.push_back((uint8_t)(v | 0x80)); v >>= 7; } o.push_back((uint8_t)v); }
static inline uint64_t zz(int64_t d) { return ((uint64_t)d << 1) ^ (uint64_t)(d >> 63); }
struct Stats { uint64_t lit = 0, refb = 0, rcb = 0, selfb = 0, nref = 0, nself = 0, tag[4] = {0, 0, 0, 0}; };
static const double LITB = 0.27;                                      // bytes per literal base after the open DNA pack (approx.)

static inline uint8_t comp(uint8_t c) { return rr_comp(c); }
static inline bool kmer_rc(const uint8_t* p, uint64_t* k) { uint64_t x = 0; for (int j = K - 1; j >= 0; j--) { int c = code2(p[j]); if (c < 0) return false; x = (x << 2) | (uint64_t)(3 - c); } *k = x; return true; }
// A[0..n) against the reverse complement read downwards from R[top-1]
static inline uint32_t lcp_rc(const uint8_t* a, const uint8_t* R, uint64_t top, uint64_t n) { uint64_t j = 0; while (j < n && j < top && a[j] == comp(R[top - 1 - j])) j++; return (uint32_t)j; }

static void encode_block(const uint8_t* A, uint64_t bs, uint64_t be, const std::vector<uint8_t>& R, const Index& I,
                         std::vector<uint8_t>& tok, std::vector<uint8_t>& lit, Stats& S) {
    const uint64_t Rn = R.size(); int32_t head[4096]; for (auto& h : head) h = -1; uint64_t ip = bs;
    uint64_t i = bs, ls = bs, ptr = 0, a_end = 0; int rc = 0;
    auto hash12 = [&](uint64_t p) { uint64_t x; uint32_t y; memcpy(&x, A + p, 8); memcpy(&y, A + p + 8, 4); return (uint32_t)(mix(x ^ ((uint64_t)y << 32)) >> 52); };
    auto expect = [&](uint64_t at, int dir, uint64_t L) -> int64_t { const int64_t g = (int64_t)((at - bs) - a_end);
        return dir ? (int64_t)ptr - g - (int64_t)L : (int64_t)ptr + g; };
    // token cost of a reference copy (dir, p lowest, L) emitted at `at`
    auto rcost = [&](uint64_t at, int dir, uint64_t p, uint64_t L, int* tag, uint64_t* arg) -> size_t {
        if (dir == rc) { const int64_t d = (int64_t)p - expect(at, dir, L);
            if (d == 0) { *tag = 0; *arg = 0; return 1 + leb_len(L - RR_MINL); }
            if (std::llabs(d) < (1ll << 24)) { *tag = 1; *arg = zz(d); return 1 + leb_len(*arg) + leb_len(L - RR_MINL); } }
        *tag = 2; *arg = p * 2 + (uint64_t)dir; return 1 + leb_len(*arg) + leb_len(L - RR_MINL); };
    auto emit = [&](uint64_t at, int tag, uint64_t arg, uint64_t L) {
        const uint64_t ll = at - ls; const uint8_t h = (uint8_t)tag;
        if (ll >= 63) { tok.push_back((uint8_t)(h | (63 << 2))); put_leb(tok, ll - 63); } else tok.push_back((uint8_t)(h | (ll << 2)));
        lit.insert(lit.end(), A + ls, A + at); S.lit += ll;
        if (L) { if (tag != 0) put_leb(tok, arg); put_leb(tok, L - RR_MINL); S.tag[tag]++; }
    };
    while (i < be) {
        const uint64_t rem = be - i, o = i - bs;
        double bests = 0; uint64_t bL = 0, bp = 0; int bk = -1, bdir = 0;            // bk: 0 reference, 1 self
        auto consider = [&](int dir, uint64_t p, uint32_t L) {
            if (L < RR_MINL) return; int tg; uint64_t ag; const size_t cost = rcost(i, dir, p, L, &tg, &ag);
            const double sc = L * LITB - (double)cost; if (sc > bests) { bests = sc; bL = L; bp = p; bk = 0; bdir = dir; } };
        {   // continuation in the current direction: expected position, then +-1..8
            const int64_t g = (int64_t)(o - a_end);
            for (int t = 0; t <= 16; t++) {
                const int64_t d = t == 0 ? 0 : ((t & 1) ? (t + 1) / 2 : -(t / 2));
                if (!rc) { const int64_t p = (int64_t)ptr + g + d; if (p < 0 || (uint64_t)p >= Rn) continue;
                    consider(0, (uint64_t)p, lcp(A + i, &R[(size_t)p], std::min<uint64_t>(rem, Rn - (uint64_t)p))); }
                else { const int64_t top = (int64_t)ptr - g + d; if (top <= 0 || (uint64_t)top > Rn) continue;
                    const uint32_t L = lcp_rc(A + i, R.data(), (uint64_t)top, rem); consider(1, (uint64_t)top - L, L); }
                if (bk == 0 && bL >= 32 && t == 0) break;
            }
        }
        uint64_t km;
        if (bL < 64 && rem >= (uint64_t)K) {                                           // seeds, both strands
            if (kmer(A + i, &km)) { const uint64_t b = mix(km) >> (64 - HB); int c = 0;
                for (uint32_t q = I.off[b]; q < I.off[b + 1] && c < 32; q++) { const uint64_t p = I.pos[q]; if (memcmp(&R[p], A + i, K)) continue; c++;
                    consider(0, p, lcp(A + i, &R[p], std::min<uint64_t>(rem, Rn - p))); } }
            if (kmer_rc(A + i, &km)) { const uint64_t b = mix(km) >> (64 - HB); int c = 0;
                for (uint32_t q = I.off[b]; q < I.off[b + 1] && c < 32; q++) { const uint64_t p = I.pos[q];
                    if (lcp_rc(A + i, R.data(), p + K, K) < (uint32_t)K) continue; c++;
                    const uint32_t L = lcp_rc(A + i, R.data(), p + K, rem); consider(1, p + K - L, L); } }
        }
        while (ip + 12 <= be && ip < i) { head[hash12(ip)] = (int32_t)(ip - bs); ip++; }
        uint64_t sdist = 0;
        if (rem >= 12) { const int32_t j = head[hash12(i)];                           // self, inside the block
            if (j >= 0) { uint32_t L = 0; const uint8_t* s = A + bs + j; while (L < rem && s[L] == A[i + L]) L++;
                if (L >= RR_MINL) { const uint64_t dist = o - (uint64_t)j; const double sc = L * LITB - (double)(1 + leb_len(dist) + leb_len(L - RR_MINL));
                    if (sc > bests) { bests = sc; bL = L; sdist = dist; bk = 1; } } } }
        if (bk < 0 || bests <= 1.0) { i++; continue; }
        if (bk == 0) {                                                                 // extend back into the literals
            uint64_t at = i, p = bp, L = bL;
            if (!bdir) { while (at > ls && p > 0 && R[p - 1] == A[at - 1]) { at--; p--; L++; } }
            else { while (at > ls && p + L < Rn && comp(R[p + L]) == A[at - 1]) { at--; L++; } }
            int tg; uint64_t ag; rcost(at, bdir, p, L, &tg, &ag); emit(at, tg, ag, L);
            S.refb += L; S.nref++; if (bdir) S.rcb += L;
            rc = bdir; ptr = bdir ? p : p + L; a_end = (at - bs) + L; i = at + L;
        } else { emit(i, 3, sdist, bL); S.selfb += bL; S.nself++; i += bL; }
        ls = i;
    }
    if (ls < be) emit(be, 0, 0, 0);
}

static int cmd_build(int argc, char** argv) {
    const std::string dir = argv[3]; const int T = atoi(argv[4]);
    double t0 = now_s(); Fasta RF = read_fasta(argv[2]); std::vector<uint8_t> R = upper(RF.b); RF.b.clear(); RF.b.shrink_to_fit();
    double t1 = now_s(); Index I = build_index(R, T); double t2 = now_s();
    printf("[build] reference %s: %zu bases, read %.1f s; index %zu 32-mers (every %d-th position) in %.1f s, %d threads\n", argv[2], R.size(), t1 - t0, I.pos.size(), STRIDE, t2 - t1, T);
    for (int a = 5; a < argc; a++) {
        const double s0 = now_s(); Fasta F = read_fasta(argv[a]); const std::vector<uint8_t> A = upper(F.b); const double s1 = now_s();
        const uint64_t nb = (A.size() + RR_BS - 1) / RR_BS;
        std::vector<std::vector<uint8_t>> tk(nb), lt(nb); std::vector<Stats> st(T); std::atomic<uint64_t> next{0};
        std::vector<std::thread> th; for (int t = 0; t < T; t++) th.emplace_back([&, t] { for (;;) { const uint64_t b = next.fetch_add(1); if (b >= nb) break;
            encode_block(A.data(), b * RR_BS, std::min<uint64_t>(A.size(), (b + 1) * RR_BS), R, I, tk[b], lt[b], st[t]); } });
        for (auto& x : th) x.join(); const double s2 = now_s();
        Stats S; for (auto& x : st) { S.lit += x.lit; S.refb += x.refb; S.rcb += x.rcb; S.selfb += x.selfb; S.nref += x.nref; S.nself += x.nself; for (int k = 0; k < 4; k++) S.tag[k] += x.tag[k]; }
        std::vector<uint8_t> TOK, LIT, M; uint64_t maxt = 0;
        for (uint64_t b = 0; b < nb; b++) { TOK.insert(TOK.end(), tk[b].begin(), tk[b].end()); LIT.insert(LIT.end(), lt[b].begin(), lt[b].end()); maxt = std::max<uint64_t>(maxt, tk[b].size()); }
        if (maxt > 65535) { fprintf(stderr, "token span > 65535 in a block\n"); return 3; }
        // meta: records, case runs, per-block spans
        auto p64 = [&](uint64_t v) { M.insert(M.end(), (uint8_t*)&v, (uint8_t*)&v + 8); }; auto p32 = [&](uint32_t v) { M.insert(M.end(), (uint8_t*)&v, (uint8_t*)&v + 4); };
        M.insert(M.end(), (const uint8_t*)"RRMETA1", (const uint8_t*)"RRMETA1" + 8); p64(A.size()); p32((uint32_t)F.rec.size());
        for (auto& r : F.rec) { p32((uint32_t)r.hdr.size()); M.insert(M.end(), r.hdr.begin(), r.hdr.end()); p64(r.len); p32(r.lw); }
        std::vector<uint8_t> runs; uint64_t nr = 0, last = 0;
        for (uint64_t i = 0; i < F.b.size();) { if (F.b[i] >= 'a' && F.b[i] <= 'z') { uint64_t j = i; while (j < F.b.size() && F.b[j] >= 'a' && F.b[j] <= 'z') j++; put_leb(runs, i - last); put_leb(runs, j - i); last = j; nr++; i = j; } else i++; }
        p64(nr); M.insert(M.end(), runs.begin(), runs.end()); p64(nb);
        for (uint64_t b = 0; b < nb; b++) { uint16_t x = (uint16_t)tk[b].size(), y = (uint16_t)lt[b].size(); M.insert(M.end(), (uint8_t*)&x, (uint8_t*)&x + 2); M.insert(M.end(), (uint8_t*)&y, (uint8_t*)&y + 2); }
        std::vector<uint8_t> Z(ZSTD_compressBound(M.size())); const size_t zn = ZSTD_compress(Z.data(), Z.size(), M.data(), M.size(), 19);
        const std::string nm = dir + "/" + base(argv[a]);
        spit(nm + ".tok", TOK.data(), TOK.size()); spit(nm + ".lit", LIT.data(), LIT.size()); spit(nm + ".meta.zst", Z.data(), zn);
        const uint64_t tot = A.size();
        printf("[build] %s: %zu bases, %zu records, %llu blocks; parse %.1f s (read %.1f s); copied from the reference %.3f %% (%llu copies, mean %.0f bases; reverse complement %.3f %%), "
               "self %.3f %% (%llu), literals %.3f %%; tags cont %llu / delta %llu / absolute %llu / self %llu; raw tokens %zu B, literals %zu B, meta %zu -> %zu B (zstd 19)\n",
               base(argv[a]).c_str(), A.size(), F.rec.size(), (unsigned long long)nb, s2 - s1, s1 - s0, 100.0 * S.refb / tot, (unsigned long long)S.nref, S.nref ? (double)S.refb / S.nref : 0.0, 100.0 * S.rcb / tot,
               100.0 * S.selfb / tot, (unsigned long long)S.nself, 100.0 * S.lit / tot, (unsigned long long)S.tag[0], (unsigned long long)S.tag[1], (unsigned long long)S.tag[2], (unsigned long long)S.tag[3],
               TOK.size(), LIT.size(), M.size(), zn);
        printf("RRBUILD\t%s\t%zu\t%.2f\t%.4f\t%llu\t%.1f\t%.4f\t%.4f\t%zu\t%zu\t%zu\n", base(argv[a]).c_str(), A.size(), s2 - s1, 100.0 * S.refb / tot, (unsigned long long)S.nref,
               S.nref ? (double)S.refb / S.nref : 0.0, 100.0 * S.selfb / tot, 100.0 * S.lit / tot, TOK.size(), LIT.size(), zn);
        fflush(stdout);
    }
    return 0;
}

// ---------------------------------------------------------------- reader
struct Arch : Meta { std::vector<uint8_t> tok, lit; };
static Arch load(const std::string& nm) { Arch X; static_cast<Meta&>(X) = load_meta(nm + ".meta.zst"); X.tok = slurp(nm + ".tok.aet"); X.lit = slurp(nm + ".lit.aet"); return X; }
// CPU execution of the ops: memcpy for literals, forward copies and non-overlapping self copies; the reverse complement
// through a byte table (same result as rr_exec in refrel_format.h, which the GPU kernel follows)
static uint8_t COMP[256];
static void exec_fast(const RrOp* ops, int n, const uint8_t* lit, const uint8_t* ref, uint8_t* out) {
    for (int k = 0; k < n; k++) { const RrOp& q = ops[k];
        if (q.kind == 0) memcpy(out + q.dst, lit + q.src, q.len);
        else if (q.kind == 1) memcpy(out + q.dst, ref + q.src, q.len);
        else if (q.kind == 2) { const uint32_t dist = q.dst - (uint32_t)q.src;
            if (dist >= q.len) memcpy(out + q.dst, out + q.src, q.len); else for (uint32_t j = 0; j < q.len; j++) out[q.dst + j] = out[q.src + j]; }
        else { const uint8_t* r = ref + q.src + q.len - 1; uint8_t* o = out + q.dst; for (uint32_t j = 0; j < q.len; j++) o[j] = COMP[*(r - j)]; } }
}
// bases [s, s+W) of the assembly into out; tb / lb / blk: caller's scratch
static bool rr_window(const Arch& X, const std::vector<uint8_t>& R, uint64_t s, uint64_t W, uint8_t* out, std::vector<uint8_t>& tb, std::vector<uint8_t>& lb, std::vector<RrOp>& ops, uint8_t* blk) {
    const uint64_t b0 = s / RR_BS, b1 = (s + W - 1) / RR_BS;
    const uint64_t t0 = X.to[b0], t1 = X.to[b1 + 1], l0 = X.lo[b0], l1 = X.lo[b1 + 1];
    tb.resize(t1 - t0 + 64); lb.resize(l1 - l0 + 64);
    if (t1 > t0 && aceapex_decompress_region(X.tok.data(), X.tok.size(), tb.data(), tb.size(), t0, t1 - t0) != (int64_t)(t1 - t0)) return false;
    if (l1 > l0 && aceapex_decompress_region(X.lit.data(), X.lit.size(), lb.data(), lb.size(), l0, l1 - l0) != (int64_t)(l1 - l0)) return false;
    for (uint64_t b = b0; b <= b1; b++) {
        const uint64_t bst = b * RR_BS; const uint32_t blen = (uint32_t)std::min<uint64_t>(RR_BS, X.n - bst);
        const int k = rr_parse(tb.data() + (X.to[b] - t0), (uint32_t)(X.to[b + 1] - X.to[b]), (uint32_t)(X.lo[b + 1] - X.lo[b]), R.size(), blen, ops.data(), RR_MAXOPS);
        if (k < 0) return false;
        exec_fast(ops.data(), k, lb.data() + (X.lo[b] - l0), R.data(), blk);
        const uint64_t a = std::max(s, bst), e = std::min(s + W, bst + blen); memcpy(out + (a - s), blk + (a - bst), e - a);
    }
    if (!X.low.empty()) { auto it = std::upper_bound(X.low.begin(), X.low.end(), std::make_pair(s, (uint64_t)~0ull)); if (it != X.low.begin()) --it;
        for (; it != X.low.end() && it->first < s + W; ++it) { const uint64_t a = std::max(s, it->first), e = std::min(s + W, it->first + it->second); for (uint64_t x = a; x < e; x++) out[x - s] |= 0x20; } }
    return true;
}
static int cmd_full(int argc, char** argv) {
    (void)argc; Fasta RF = read_fasta(argv[2]); std::vector<uint8_t> R = upper(RF.b); RF.b.clear();
    const double t0 = now_s(); Arch X = load(argv[3]); std::vector<uint8_t> A(X.n + 64), tb, lb, blk(RR_BS); std::vector<RrOp> ops(RR_MAXOPS);
    for (uint64_t s = 0; s < X.n; s += 1u << 20) { const uint64_t W = std::min<uint64_t>(1u << 20, X.n - s); if (!rr_window(X, R, s, W, &A[s], tb, lb, ops, blk.data())) { fprintf(stderr, "decode failed at %llu\n", (unsigned long long)s); return 4; } }
    std::string o; o.reserve(X.n + X.n / 60 + 1024);
    for (auto& r : X.rec) { o += '>'; o += r.hdr; o += '\n'; for (uint64_t x = 0; x < r.len; x += r.lw) { o.append((const char*)&A[r.boff + x], std::min<uint64_t>(r.lw, r.len - x)); o += '\n'; } }
    spit(argv[4], o.data(), o.size()); printf("[full] %s: %zu bytes of FASTA in %.1f s (1 thread)\n", argv[3], o.size(), now_s() - t0); return 0;
}
static int cmd_windows(int argc, char** argv) {
    Fasta RF = read_fasta(argv[2]); std::vector<uint8_t> R = upper(RF.b); RF.b.clear(); RF.b.shrink_to_fit();
    Arch X = load(argv[3]); Fasta F = read_fasta(argv[4]); const std::vector<uint8_t> open = slurp(argv[5]); const int T = atoi(argv[6]); const uint64_t seed = argc > 7 ? strtoull(argv[7], 0, 10) : 20261003;
    if (F.b.size() != X.n) { fprintf(stderr, "base count differs\n"); return 2; }
    printf("[win] %s: %llu bases; refrel %zu + %zu B (+ meta), open %zu B; %d threads\n", argv[3], (unsigned long long)X.n, X.tok.size(), X.lit.size(), open.size(), T);
    for (uint64_t W = 256; W <= (1u << 20); W *= 4) {
        const uint64_t n = std::min<uint64_t>(20000, std::max<uint64_t>(256, (1ull << 31) / W) );
        std::mt19937_64 g(seed + W); std::vector<uint64_t> off(n); for (auto& x : off) x = g() % (X.n - W + 1);
        for (int which = 0; which < 2; which++) {
            std::atomic<uint64_t> next{0}; std::atomic<int> bad{0};
            const double t0 = now_s();
            std::vector<std::thread> th; for (int t = 0; t < T; t++) th.emplace_back([&] {
                std::vector<uint8_t> out(W + 64), tb, lb, blk(RR_BS), fb; std::vector<RrOp> ops(RR_MAXOPS);
                for (;;) { const uint64_t q = next.fetch_add(1); if (q >= n) break; const uint64_t s = off[q]; bool ok = true;
                    if (which == 0) ok = rr_window(X, R, s, W, out.data(), tb, lb, ops, blk.data());
                    else {                                                    // open: per record, FASTA bytes -> bases
                        uint64_t got = 0; auto it = std::upper_bound(F.rec.begin(), F.rec.end(), s, [](uint64_t v, const Rec& r) { return v < r.boff; }); --it;
                        for (; got < W && it != F.rec.end(); ++it) { const uint64_t a = std::max(s + got, it->boff) - it->boff, e = std::min(s + W, it->boff + it->len) - it->boff; if (e <= a) continue;
                            auto bo = [&](uint64_t x) { return it->foff + x / it->lw * (it->lw + 1) + x % it->lw; };
                            const uint64_t lo = bo(a), hi = bo(e - 1) + 1; fb.resize(hi - lo + 64);
                            if (aceapex_decompress_region(open.data(), open.size(), fb.data(), fb.size(), lo, hi - lo) != (int64_t)(hi - lo)) { ok = false; break; }
                            for (uint64_t k = 0; k < hi - lo; k++) if (fb[k] != '\n') out[got++] = fb[k]; }
                        ok = ok && got == W;
                    }
                    if (!ok || memcmp(out.data(), &F.b[s], W)) bad++; } });
            for (auto& x : th) x.join(); const double dt = now_s() - t0;
            printf("RRWIN\t%s\t%llu\t%llu\t%d\t%.0f\t%.3f\t%s\n", which ? "open" : "refrel", (unsigned long long)W, (unsigned long long)n, T, n / dt, n * W / dt / 1e9, bad ? "DIFFERS" : "ok"); fflush(stdout);
        }
    }
    return 0;
}
int main(int argc, char** argv) {
    for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
    if (argc >= 6 && !strcmp(argv[1], "build")) return cmd_build(argc, argv);
    if (argc >= 5 && !strcmp(argv[1], "full")) return cmd_full(argc, argv);
    if (argc >= 7 && !strcmp(argv[1], "windows")) return cmd_windows(argc, argv);
    fprintf(stderr, "usage: refrel build <ref.fa> <out_dir> <threads> <asm.fa>... | full <ref.fa> <dir/name> <out.fa> | windows <ref.fa> <dir/name> <asm.fa> <asm.open.aet> <threads> [seed]\n");
    return 1;
}
