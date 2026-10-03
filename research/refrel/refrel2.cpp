// refrel2.cpp - token-model experiments on refrel (refrel_v2.h): field split and carried block state, measured on the
// same assemblies as v1 (refrel.cpp); v1 tool, format and GPU path unchanged.
//   refrel2 build <ref.fa> <out_dir> <threads> <split 0|1> <carry 0|1> <asm.fa>...
//       writes <name>.t0 .. .t5 (split) or <name>.t0 (one stream), <name>.lit, <name>.meta2.zst
//   refrel2 full <ref.fa> <dir/name> <out.fa>          from the .tK.aet / .lit.aet archives (CLI open profile)
//   refrel2 windows <ref.fa> <dir/name> <asm.fa> <threads> [seed]   refrel windows only (open: refrel.cpp windows)
// Build: g++ -std=c++17 -O3 -march=native -funroll-loops -Isrc research/refrel/refrel2.cpp src/aceapex_api.cpp -lzstd -lpthread
#define main refrel_v1_main
#include "refrel.cpp"
#undef main
#include "refrel_v2.h"

struct Tok6 { std::vector<uint8_t> v[6]; bool split; std::vector<uint8_t>& at(int k) { return v[split ? k : 0]; } };
struct BlockEnd { uint64_t ptr = 0, a_end = 0; int rc = 0; };

// v1 encoder with a stored initial state and the fields routed to six streams
static BlockEnd encode_block2(const uint8_t* A, uint64_t bs, uint64_t be, const std::vector<uint8_t>& R, const Index& I,
                              Tok6& tok, std::vector<uint8_t>& lit, Stats& S, uint64_t ptr0, int rc0) {
    const uint64_t Rn = R.size(); int32_t head[4096]; for (auto& h : head) h = -1; uint64_t ip = bs;
    uint64_t i = bs, ls = bs, ptr = ptr0, a_end = 0; int rc = rc0;
    auto hash12 = [&](uint64_t p) { uint64_t x; uint32_t y; memcpy(&x, A + p, 8); memcpy(&y, A + p + 8, 4); return (uint32_t)(mix(x ^ ((uint64_t)y << 32)) >> 52); };
    auto expect = [&](uint64_t at, int dir, uint64_t L) -> int64_t { const int64_t g = (int64_t)((at - bs) - a_end); return dir ? (int64_t)ptr - g - (int64_t)L : (int64_t)ptr + g; };
    auto rcost = [&](uint64_t at, int dir, uint64_t p, uint64_t L, int* tag, uint64_t* arg) -> size_t {
        if (dir == rc) { const int64_t d = (int64_t)p - expect(at, dir, L);
            if (d == 0) { *tag = 0; *arg = 0; return 1 + leb_len(L - RR_MINL); }
            if (std::llabs(d) < (1ll << 24)) { *tag = 1; *arg = zz(d); return 1 + leb_len(*arg) + leb_len(L - RR_MINL); } }
        *tag = 2; *arg = p * 2 + (uint64_t)dir; return 1 + leb_len(*arg) + leb_len(L - RR_MINL); };
    auto emit = [&](uint64_t at, int tag, uint64_t arg, uint64_t L) {
        const uint64_t ll = at - ls; const uint8_t h = (uint8_t)tag;
        if (ll >= 63) { tok.at(0).push_back((uint8_t)(h | (63 << 2))); put_leb(tok.at(1), ll - 63); } else tok.at(0).push_back((uint8_t)(h | (ll << 2)));
        lit.insert(lit.end(), A + ls, A + at); S.lit += ll;
        if (L) { if (tag != 0) put_leb(tok.at(2 + tag), arg); put_leb(tok.at(2), L - RR_MINL); S.tag[tag]++; }
    };
    while (i < be) {
        const uint64_t rem = be - i, o = i - bs;
        double bests = 0; uint64_t bL = 0, bp = 0; int bk = -1, bdir = 0;
        auto consider = [&](int dir, uint64_t p, uint32_t L) {
            if (L < RR_MINL) return; int tg; uint64_t ag; const size_t cost = rcost(i, dir, p, L, &tg, &ag);
            const double sc = L * LITB - (double)cost; if (sc > bests) { bests = sc; bL = L; bp = p; bk = 0; bdir = dir; } };
        { const int64_t g = (int64_t)(o - a_end);
          for (int t = 0; t <= 16; t++) { const int64_t d = t == 0 ? 0 : ((t & 1) ? (t + 1) / 2 : -(t / 2));
            if (!rc) { const int64_t p = (int64_t)ptr + g + d; if (p < 0 || (uint64_t)p >= Rn) continue; consider(0, (uint64_t)p, lcp(A + i, &R[(size_t)p], std::min<uint64_t>(rem, Rn - (uint64_t)p))); }
            else { const int64_t top = (int64_t)ptr - g + d; if (top <= 0 || (uint64_t)top > Rn) continue; const uint32_t L = lcp_rc(A + i, R.data(), (uint64_t)top, rem); consider(1, (uint64_t)top - L, L); }
            if (bk == 0 && bL >= 32 && t == 0) break; } }
        uint64_t km;
        if (bL < 64 && rem >= (uint64_t)K) {
            if (kmer(A + i, &km)) { const uint64_t b = mix(km) >> (64 - HB); int c = 0;
                for (uint32_t q = I.off[b]; q < I.off[b + 1] && c < 32; q++) { const uint64_t p = I.pos[q]; if (memcmp(&R[p], A + i, K)) continue; c++; consider(0, p, lcp(A + i, &R[p], std::min<uint64_t>(rem, Rn - p))); } }
            if (kmer_rc(A + i, &km)) { const uint64_t b = mix(km) >> (64 - HB); int c = 0;
                for (uint32_t q = I.off[b]; q < I.off[b + 1] && c < 32; q++) { const uint64_t p = I.pos[q]; if (lcp_rc(A + i, R.data(), p + K, K) < (uint32_t)K) continue; c++;
                    const uint32_t L = lcp_rc(A + i, R.data(), p + K, rem); consider(1, p + K - L, L); } } }
        while (ip + 12 <= be && ip < i) { head[hash12(ip)] = (int32_t)(ip - bs); ip++; }
        uint64_t sdist = 0;
        if (rem >= 12) { const int32_t j = head[hash12(i)];
            if (j >= 0) { uint32_t L = 0; const uint8_t* s = A + bs + j; while (L < rem && s[L] == A[i + L]) L++;
                if (L >= RR_MINL) { const uint64_t dist = o - (uint64_t)j; const double sc = L * LITB - (double)(1 + leb_len(dist) + leb_len(L - RR_MINL)); if (sc > bests) { bests = sc; bL = L; sdist = dist; bk = 1; } } } }
        if (bk < 0 || bests <= 1.0) { i++; continue; }
        if (bk == 0) { uint64_t at = i, p = bp, L = bL;
            if (!bdir) { while (at > ls && p > 0 && R[p - 1] == A[at - 1]) { at--; p--; L++; } } else { while (at > ls && p + L < Rn && comp(R[p + L]) == A[at - 1]) { at--; L++; } }
            int tg; uint64_t ag; rcost(at, bdir, p, L, &tg, &ag); emit(at, tg, ag, L);
            S.refb += L; S.nref++; if (bdir) S.rcb += L; rc = bdir; ptr = bdir ? p : p + L; a_end = (at - bs) + L; i = at + L;
        } else { emit(i, 3, sdist, bL); S.selfb += bL; S.nself++; i += bL; }
        ls = i;
    }
    if (ls < be) emit(be, 0, 0, 0);
    BlockEnd e; e.ptr = ptr; e.a_end = a_end; e.rc = rc; return e;
}
// the state that block b+1 starts from, given where block b ended: the last reference copy continued over the rest of b
static inline void next_state(const BlockEnd& e, uint64_t blen, uint64_t* ptr, int* rc) {
    *rc = e.rc; const int64_t g = (int64_t)(blen - e.a_end); const int64_t p = e.rc ? (int64_t)e.ptr - g : (int64_t)e.ptr + g; *ptr = p < 0 ? 0 : (uint64_t)p; }

static int cmd_build2(int argc, char** argv) {
    const std::string dir = argv[3]; const int T = atoi(argv[4]); const bool split = atoi(argv[5]) != 0, carry = atoi(argv[6]) != 0;
    Fasta RF = read_fasta(argv[2]); std::vector<uint8_t> R = upper(RF.b); RF.b.clear(); RF.b.shrink_to_fit(); Index I = build_index(R, T);
    for (int a = 7; a < argc; a++) {
        Fasta F = read_fasta(argv[a]); const std::vector<uint8_t> A = upper(F.b); const double s1 = now_s();
        const uint64_t nb = (A.size() + RR_BS - 1) / RR_BS;
        std::vector<Tok6> tk(nb); std::vector<std::vector<uint8_t>> lt(nb); std::vector<BlockEnd> be(nb); std::vector<uint64_t> p0(nb, 0); std::vector<int> r0(nb, 0);
        auto pass = [&](std::vector<Stats>& st) { std::atomic<uint64_t> next{0}; std::vector<std::thread> th;
            for (int t = 0; t < T; t++) th.emplace_back([&, t] { for (;;) { const uint64_t b = next.fetch_add(1); if (b >= nb) break;
                tk[b] = Tok6(); tk[b].split = split; lt[b].clear();
                be[b] = encode_block2(A.data(), b * RR_BS, std::min<uint64_t>(A.size(), (b + 1) * RR_BS), R, I, tk[b], lt[b], st[t], p0[b], r0[b]); } });
            for (auto& x : th) x.join(); };
        std::vector<Stats> st(T); pass(st);
        if (carry) {                                                    // second pass from the first pass's block ends
            for (uint64_t b = 1; b < nb; b++) next_state(be[b - 1], RR_BS, &p0[b], &r0[b]);
            st.assign(T, Stats()); pass(st);
        }
        const double s2 = now_s();
        Stats S; for (auto& x : st) { S.lit += x.lit; S.refb += x.refb; S.nref += x.nref; for (int k = 0; k < 4; k++) S.tag[k] += x.tag[k]; }
        const int NS = split ? 6 : 1; std::vector<std::vector<uint8_t>> TS(NS); std::vector<uint8_t> LIT, M;
        for (uint64_t b = 0; b < nb; b++) { for (int k = 0; k < NS; k++) TS[k].insert(TS[k].end(), tk[b].v[k].begin(), tk[b].v[k].end()); LIT.insert(LIT.end(), lt[b].begin(), lt[b].end()); }
        auto p64 = [&](uint64_t v) { M.insert(M.end(), (uint8_t*)&v, (uint8_t*)&v + 8); }; auto p32 = [&](uint32_t v) { M.insert(M.end(), (uint8_t*)&v, (uint8_t*)&v + 4); };
        M.insert(M.end(), (const uint8_t*)"RRMETA2", (const uint8_t*)"RRMETA2" + 8); p32((split ? 1 : 0) | (carry ? 2 : 0)); p64(A.size()); p32((uint32_t)F.rec.size());
        for (auto& r : F.rec) { p32((uint32_t)r.hdr.size()); M.insert(M.end(), r.hdr.begin(), r.hdr.end()); p64(r.len); p32(r.lw); }
        std::vector<uint8_t> runs; uint64_t nr = 0, last = 0;
        for (uint64_t i = 0; i < F.b.size();) { if (F.b[i] >= 'a' && F.b[i] <= 'z') { uint64_t j = i; while (j < F.b.size() && F.b[j] >= 'a' && F.b[j] <= 'z') j++; put_leb(runs, i - last); put_leb(runs, j - i); last = j; nr++; i = j; } else i++; }
        p64(nr); M.insert(M.end(), runs.begin(), runs.end()); p64(nb);
        uint64_t prev = 0; int prc = 0; size_t mspan = 0, mstate = 0;
        for (uint64_t b = 0; b < nb; b++) { const size_t m0 = M.size();
            for (int k = 0; k < NS; k++) put_leb(M, tk[b].v[k].size()); put_leb(M, lt[b].size()); const size_t m1 = M.size(); mspan += m1 - m0;
            if (carry) { const int64_t pred = b == 0 ? 0 : (prc ? (int64_t)prev - (int64_t)RR_BS : (int64_t)prev + (int64_t)RR_BS);
                put_leb(M, zz((int64_t)p0[b] - pred) * 2 + (uint64_t)r0[b]); prev = p0[b]; prc = r0[b]; mstate += M.size() - m1; } }
        std::vector<uint8_t> Z(ZSTD_compressBound(M.size())); const size_t zn = ZSTD_compress(Z.data(), Z.size(), M.data(), M.size(), 19);
        const std::string nm = dir + "/" + base(argv[a]);
        for (int k = 0; k < NS; k++) spit(nm + ".t" + std::to_string(k), TS[k].data(), TS[k].size());
        spit(nm + ".lit", LIT.data(), LIT.size()); spit(nm + ".meta2.zst", Z.data(), zn);
        printf("RR2BUILD\t%s\tsplit %d carry %d\tparse %.2f s\ttags %llu/%llu/%llu/%llu\tstreams", base(argv[a]).c_str(), split, carry, s2 - s1,
               (unsigned long long)S.tag[0], (unsigned long long)S.tag[1], (unsigned long long)S.tag[2], (unsigned long long)S.tag[3]);
        size_t tot = 0; for (int k = 0; k < NS; k++) { printf(" %zu", TS[k].size()); tot += TS[k].size(); }
        printf("\traw tokens %zu\tlit %zu\tmeta raw %zu (spans %zu, states %zu) zst %zu\n", tot, LIT.size(), M.size(), mspan, mstate, zn); fflush(stdout);
    }
    return 0;
}

struct Arch2 { Meta M; int NS = 1; bool carry = false; std::vector<std::vector<uint8_t>> ts; std::vector<std::vector<uint64_t>> off; std::vector<uint64_t> p0; std::vector<uint8_t> r0; std::vector<uint8_t> lit; };
static Arch2 load2(const std::string& nm) {
    Arch2 X; std::vector<uint8_t> z = slurp(nm + ".meta2.zst"); const unsigned long long mn = ZSTD_getFrameContentSize(z.data(), z.size());
    std::vector<uint8_t> M((size_t)mn); if (ZSTD_decompress(M.data(), M.size(), z.data(), z.size()) != mn) { fprintf(stderr, "meta2\n"); exit(2); }
    size_t i = 8; auto g64 = [&] { uint64_t v; memcpy(&v, &M[i], 8); i += 8; return v; }; auto g32 = [&] { uint32_t v; memcpy(&v, &M[i], 4); i += 4; return v; };
    auto gl = [&] { uint64_t v = 0; int sh = 0; for (;;) { uint8_t c = M[i++]; v |= (uint64_t)(c & 0x7F) << sh; if (!(c & 0x80)) break; sh += 7; } return v; };
    const uint32_t fl = g32(); X.NS = (fl & 1) ? 6 : 1; X.carry = (fl & 2) != 0;
    X.M.n = g64(); const uint32_t nr = g32(); uint64_t bo = 0;
    for (uint32_t r = 0; r < nr; r++) { Rec q; const uint32_t hl = g32(); q.hdr.assign((const char*)&M[i], hl); i += hl; q.len = g64(); q.lw = g32(); q.boff = bo; bo += q.len; q.foff = 0; X.M.rec.push_back(q); }
    const uint64_t nl = g64(); uint64_t last = 0; for (uint64_t k = 0; k < nl; k++) { const uint64_t g = gl(), l = gl(); X.M.low.push_back({last + g, l}); last += g + l; }
    X.M.nb = g64(); X.off.assign(X.NS + 1, std::vector<uint64_t>(X.M.nb + 1, 0)); X.p0.assign(X.M.nb, 0); X.r0.assign(X.M.nb, 0);
    uint64_t prev = 0; int prc = 0;
    for (uint64_t b = 0; b < X.M.nb; b++) { for (int k = 0; k <= X.NS; k++) X.off[k][b + 1] = X.off[k][b] + gl();
        if (X.carry) { const uint64_t v = gl(); const int64_t pred = b == 0 ? 0 : (prc ? (int64_t)prev - (int64_t)RR_BS : (int64_t)prev + (int64_t)RR_BS);
            const uint64_t q = v >> 1; X.r0[b] = (uint8_t)(v & 1); X.p0[b] = (uint64_t)(pred + ((int64_t)(q >> 1) ^ -(int64_t)(q & 1))); prev = X.p0[b]; prc = X.r0[b]; } }
    for (int k = 0; k < X.NS; k++) X.ts.push_back(slurp(nm + ".t" + std::to_string(k) + ".aet"));
    X.lit = slurp(nm + ".lit.aet");
    return X;
}
static bool rr2_window(const Arch2& X, const std::vector<uint8_t>& R, uint64_t s, uint64_t W, uint8_t* out, std::vector<std::vector<uint8_t>>& buf, std::vector<RrOp>& ops, uint8_t* blk) {
    const uint64_t b0 = s / RR_BS, b1 = (s + W - 1) / RR_BS; buf.resize(X.NS + 1);
    for (int k = 0; k <= X.NS; k++) { const auto& o = X.off[k]; const uint64_t a = o[b0], e = o[b1 + 1]; buf[k].resize(e - a + 64);
        const std::vector<uint8_t>& arc = k < X.NS ? X.ts[k] : X.lit;
        if (e > a && aceapex_decompress_region(arc.data(), arc.size(), buf[k].data(), buf[k].size(), a, e - a) != (int64_t)(e - a)) return false; }
    for (uint64_t b = b0; b <= b1; b++) {
        const uint64_t bst = b * RR_BS; const uint32_t blen = (uint32_t)std::min<uint64_t>(RR_BS, X.M.n - bst);
        RrCur cur[6]; RrSrc src;
        for (int k = 0; k < X.NS; k++) { cur[k].p = buf[k].data() + (X.off[k][b] - X.off[k][b0]); cur[k].n = (uint32_t)(X.off[k][b + 1] - X.off[k][b]); cur[k].i = 0; }
        for (int k = 0; k < 6; k++) src.c[k] = &cur[X.NS == 6 ? k : 0];
        const uint32_t ln = (uint32_t)(X.off[X.NS][b + 1] - X.off[X.NS][b]);
        const int n = rr_parse2(src, ln, R.size(), blen, X.carry ? X.p0[b] : 0, X.carry ? X.r0[b] : 0, ops.data(), RR_MAXOPS);
        if (n < 0) return false;
        for (int k = 0; k < X.NS; k++) if (cur[k].i != cur[k].n) return false;
        exec_fast(ops.data(), n, buf[X.NS].data() + (X.off[X.NS][b] - X.off[X.NS][b0]), R.data(), blk);
        const uint64_t a = std::max(s, bst), e = std::min(s + W, bst + blen); memcpy(out + (a - s), blk + (a - bst), e - a);
    }
    if (!X.M.low.empty()) { auto it = std::upper_bound(X.M.low.begin(), X.M.low.end(), std::make_pair(s, (uint64_t)~0ull)); if (it != X.M.low.begin()) --it;
        for (; it != X.M.low.end() && it->first < s + W; ++it) { const uint64_t a = std::max(s, it->first), e = std::min(s + W, it->first + it->second); for (uint64_t x = a; x < e; x++) out[x - s] |= 0x20; } }
    return true;
}
static int cmd_full2(char** argv) {
    Fasta RF = read_fasta(argv[2]); std::vector<uint8_t> R = upper(RF.b); RF.b.clear();
    const double t0 = now_s(); Arch2 X = load2(argv[3]); std::vector<uint8_t> A(X.M.n + 64), blk(RR_BS); std::vector<std::vector<uint8_t>> buf; std::vector<RrOp> ops(RR_MAXOPS);
    for (uint64_t s = 0; s < X.M.n; s += 1u << 20) { const uint64_t W = std::min<uint64_t>(1u << 20, X.M.n - s); if (!rr2_window(X, R, s, W, &A[s], buf, ops, blk.data())) { fprintf(stderr, "decode failed at %llu\n", (unsigned long long)s); return 4; } }
    std::string o; o.reserve(X.M.n + X.M.n / 60 + 1024);
    for (auto& r : X.M.rec) { o += '>'; o += r.hdr; o += '\n'; for (uint64_t x = 0; x < r.len; x += r.lw) { o.append((const char*)&A[r.boff + x], std::min<uint64_t>(r.lw, r.len - x)); o += '\n'; } }
    spit(argv[4], o.data(), o.size()); printf("[full2] %s: %zu bytes in %.1f s\n", argv[3], o.size(), now_s() - t0); return 0;
}
static int cmd_windows2(int argc, char** argv) {
    Fasta RF = read_fasta(argv[2]); std::vector<uint8_t> R = upper(RF.b); RF.b.clear(); RF.b.shrink_to_fit();
    Arch2 X = load2(argv[3]); Fasta F = read_fasta(argv[4]); const int T = atoi(argv[5]); const uint64_t seed = argc > 6 ? strtoull(argv[6], 0, 10) : 20261003;
    for (uint64_t W = 256; W <= (1u << 20); W *= 4) {
        const uint64_t n = std::min<uint64_t>(20000, std::max<uint64_t>(256, (1ull << 31) / W)); std::mt19937_64 g(seed + W); std::vector<uint64_t> off(n); for (auto& x : off) x = g() % (X.M.n - W + 1);
        std::atomic<uint64_t> next{0}; std::atomic<int> bad{0}; const double t0 = now_s(); std::vector<std::thread> th;
        for (int t = 0; t < T; t++) th.emplace_back([&] { std::vector<uint8_t> out(W + 64), blk(RR_BS); std::vector<std::vector<uint8_t>> buf; std::vector<RrOp> ops(RR_MAXOPS);
            for (;;) { const uint64_t q = next.fetch_add(1); if (q >= n) break; if (!rr2_window(X, R, off[q], W, out.data(), buf, ops, blk.data()) || memcmp(out.data(), &F.b[off[q]], W)) bad++; } });
        for (auto& x : th) x.join(); const double dt = now_s() - t0;
        printf("RR2WIN\t%llu\t%llu\t%d\t%.0f\t%.3f\t%s\n", (unsigned long long)W, (unsigned long long)n, T, n / dt, n * W / dt / 1e9, bad ? "DIFFERS" : "ok"); fflush(stdout);
    }
    return 0;
}
int main(int argc, char** argv) {
    for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
    if (argc >= 8 && !strcmp(argv[1], "build")) return cmd_build2(argc, argv);
    if (argc >= 5 && !strcmp(argv[1], "full")) return cmd_full2(argv);
    if (argc >= 6 && !strcmp(argv[1], "windows")) return cmd_windows2(argc, argv);
    fprintf(stderr, "usage: refrel2 build <ref.fa> <dir> <threads> <split 0|1> <carry 0|1> <asm.fa>... | full <ref.fa> <dir/name> <out.fa> | windows <ref.fa> <dir/name> <asm.fa> <threads> [seed]\n");
    return 1;
}
