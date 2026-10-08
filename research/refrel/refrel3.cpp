// refrel3.cpp - edits against the decoded reference with static context models (refrel3.h); research, v1 / v2 untouched.
//   refrel3 build <ref.fa> <out_dir> <threads> <asm.fa>...   -> <name>.r3 (block streams) + <name>.meta3.zst
//   refrel3 full <ref.fa> <dir/name> <out.fa>                 full decode (cmp with the FASTA)
//   refrel3 windows <ref.fa> <dir/name> <asm.fa> <threads> [seed]   random windows W = 256 B .. 1 MiB, == FASTA
// The reference may be T2T or T2T plus a secondary sequence (3b): any FASTA; positions index its upper-case bases.
// Build: g++ -std=c++17 -O3 -march=native -funroll-loops -Isrc -Iresearch/refrel research/refrel/refrel3.cpp src/aceapex_api.cpp -lzstd -lpthread
#define RR2_NO_MAIN
#include "refrel2.cpp"
#include "refrel3.h"
#include <sys/stat.h>
#include <unistd.h>

struct Sym { uint16_t ctx; uint16_t s; uint32_t nb; uint64_t raw; };    // ctx 0xFFFF: raw bits only (nb, raw)
struct Ev { uint32_t at, L; int kind; uint32_t dir; uint64_t p; };    // kind 0 reference, 1 self (p = distance)

// ---------------------------------------------------------------- parse: v1+carry parse with the diagonal cache
struct PState { R3Diag cache[4]; int nc; };
static R3Diag parse_block(const uint8_t* A, uint64_t bs, uint64_t be, const std::vector<uint8_t>& R, const Index& I, R3Diag start, std::vector<Ev>& ev) {
    const uint64_t Rn = R.size(); int32_t head[4096]; for (auto& h : head) h = -1; uint64_t ip = bs; uint64_t i = bs, ls = bs;
    PState S; S.cache[0] = start; S.nc = 1;
    auto hash12 = [&](uint64_t p) { uint64_t x; uint32_t y; memcpy(&x, A + p, 8); memcpy(&y, A + p + 8, 4); return (uint32_t)(mix(x ^ ((uint64_t)y << 32)) >> 52); };
    // approximate cost in bytes of a reference copy (dir, p, L) at block offset o (the coder's kinds)
    auto rcost = [&](uint32_t o, uint32_t dir, uint64_t p, uint64_t L) -> double {
        double best = 4.6;                                                   // ABS: kind + strand + 32 bits
        for (int k = 0; k < S.nc; k++) { int64_t d;
            if (S.cache[k].dir == dir) { d = (int64_t)p - r3_exp(S.cache[k], o, L); if (k == 0 && d == 0) { best = std::min(best, 0.35); continue; } }
            else d = (int64_t)p - r3_locus(S.cache[k], o);
            const uint64_t a = (uint64_t)std::llabs(d); if ((int64_t)a >= R3_DLIM) continue;
            const double bits = (a ? 64 - __builtin_clzll(a) : 0) + 6.0 + (k || S.cache[k].dir != dir ? 2.0 : 0.0); best = std::min(best, bits / 8.0); }
        return best + 1.0;                                                   // + length
    };
    while (i < be) {
        const uint64_t rem = be - i; const uint32_t o = (uint32_t)(i - bs);
        double bests = 0; uint64_t bL = 0, bp = 0; int bk = -1; uint32_t bdir = 0;
        auto consider = [&](uint32_t dir, uint64_t p, uint32_t L) { if (L < RR_MINL) return; const double sc = L * LITB - rcost(o, dir, p, L); if (sc > bests) { bests = sc; bL = L; bp = p; bk = 0; bdir = dir; } };
        for (int k = 0; k < S.nc; k++) { const R3Diag g = S.cache[k];             // continuation on the cached diagonals
            for (int t = 0; t <= (k == 0 ? 16 : 4); t++) { const int64_t dd = t == 0 ? 0 : ((t & 1) ? (t + 1) / 2 : -(t / 2));
                if (!g.dir) { const int64_t p = (int64_t)g.c + o + dd; if (p < 0 || (uint64_t)p >= Rn) continue; consider(0, (uint64_t)p, lcp(A + i, &R[(size_t)p], std::min<uint64_t>(rem, Rn - (uint64_t)p))); }
                else { const int64_t top = (int64_t)g.c - o + 1 + dd; if (top <= 0 || (uint64_t)top > Rn) continue; const uint32_t L = lcp_rc(A + i, R.data(), (uint64_t)top, rem); consider(1, (uint64_t)top - L, L); }
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
                if (L >= RR_MINL) { const uint64_t dist = o - (uint64_t)j; const double sc = L * LITB - (1.0 + 2.0 * (64 - __builtin_clzll(dist)) / 8.0 + 1.0); if (sc > bests) { bests = sc; bL = L; sdist = dist; bk = 1; } } } }
        if (bk < 0 || bests <= 0.5) { i++; continue; }
        if (bk == 0) { uint64_t at = i, p = bp, L = bL;
            if (!bdir) { while (at > ls && p > 0 && R[p - 1] == A[at - 1]) { at--; p--; L++; } } else { while (at > ls && p + L < Rn && comp(R[p + L]) == A[at - 1]) { at--; L++; } }
            ev.push_back({(uint32_t)(at - bs), (uint32_t)L, 0, bdir, p}); r3_push(S.cache, &S.nc, r3_diag(bdir, p, (uint32_t)(at - bs), L)); i = at + L;
        } else { ev.push_back({o, (uint32_t)bL, 1, 0, sdist}); i += bL; }
        ls = i;
    }
    return S.cache[0];
}

// ---------------------------------------------------------------- events -> symbols (the decoder's order and contexts)
static void put_val(std::vector<Sym>& out, int ctx, uint64_t v) { uint32_t nb; uint64_t ex; const uint32_t s = r3_bucket(v, &nb, &ex); out.push_back({(uint16_t)ctx, (uint16_t)s, 0, 0}); if (nb) out.push_back({0xFFFF, 0, nb, ex}); }
static uint64_t g_absstat[5][65];
static void symbols(const uint8_t* A, uint64_t bs, uint32_t blen, const std::vector<Ev>& ev, const std::vector<uint8_t>& R, R3Diag start, std::vector<Sym>& out) {
    R3Diag cache[4]; int nc = 1; cache[0] = start; int prevk = -1; uint32_t o = 0; size_t e = 0;
    while (o < blen) {
        const uint32_t next = e < ev.size() ? ev[e].at : blen; const uint64_t ll = next - o;
        put_val(out, R3_LL + r3_kclass(prevk), ll);
        uint32_t p1 = 16, p2 = 16;
        for (uint32_t j = 0; j < ll; j++) { const uint8_t b = A[bs + o + j]; int c;
            if (ll <= 8) c = R3_LITR + r3_refbase(R.data(), R.size(), cache[0], o + j) * 2 + (j == 0 ? 1 : 0);
            else c = R3_LIT2 + (p1 == 16 ? 16 : (int)(p2 == 16 ? p1 : p2 * 4 + p1) % 16);
            const int s = r3_b2(b); out.push_back({(uint16_t)c, (uint16_t)s, 0, 0}); if (s == 5) out.push_back({0xFFFF, 0, 8, b});
            p2 = p1; p1 = s < 4 ? (uint32_t)s : 0; }
        o += (uint32_t)ll; if (o == blen) break;
        const Ev& v = ev[e++]; int kind; int ki = 0; uint64_t z = 0;
        if (v.kind == 1) kind = K_SELF;
        else { kind = K_ABS; double best = 1e9;
            for (int k = 0; k < nc; k++) { const bool same = cache[k].dir == v.dir;
                const int64_t d = same ? (int64_t)v.p - r3_exp(cache[k], o, v.L) : (int64_t)v.p - r3_locus(cache[k], o);
                const uint64_t a = (uint64_t)std::llabs(d); if ((int64_t)a >= R3_DLIM) continue;
                const double cost = (same && k == 0 && d == 0) ? 0 : (a ? 64 - __builtin_clzll(a) : 0) + 6.0 + (k || !same ? 2.0 : 0.0);
                if (cost < best) { best = cost; kind = !same ? K_FLIP : k == 0 ? (d == 0 ? K_CONT : K_DELTA) : K_REP; ki = k; z = zz(d); } } }
        if (kind == K_ABS && getenv("RR3_ABSSTAT")) {                   // where do absolute jumps land, relative to the cached diagonals
            uint64_t best = ~0ull; int how = 0;
            for (int k = 0; k < nc; k++) { const int64_t q = cache[k].dir ? (int64_t)cache[k].c - (int64_t)o : (int64_t)cache[k].c + (int64_t)o;   // the locus the diagonal is at
                const uint64_t a1 = (uint64_t)std::llabs((int64_t)v.p - q), a2 = (uint64_t)std::llabs((int64_t)(v.p + v.L) - q); const uint64_t a = std::min(a1, a2);
                if (a < best) { best = a; how = (cache[k].dir == v.dir ? 1 : 2) + (k ? 2 : 0); } }
            const int lg = best ? 64 - __builtin_clzll(best) : 0; __atomic_fetch_add(&g_absstat[how][lg], 1, __ATOMIC_RELAXED); }
        out.push_back({(uint16_t)(R3_KIND + r3_llc(ll) * 4 + r3_kclass(prevk)), (uint16_t)kind, 0, 0});
        if (kind == K_DELTA) put_val(out, R3_DELTA + (ll == 0 ? 0 : 1), z);
        else if (kind == K_REP) { out.push_back({R3_REPK, (uint16_t)(ki - 1), 0, 0}); put_val(out, R3_REPD, z); }
        else if (kind == K_ABS) { out.push_back({R3_DIR, (uint16_t)v.dir, 0, 0}); out.push_back({0xFFFF, 0, 32, v.p}); }
        else if (kind == K_SELF) put_val(out, R3_SELF, v.p);
        else if (kind == K_FLIP) { out.push_back({R3_FLIPK, (uint16_t)ki, 0, 0}); put_val(out, R3_FLIPD, z); }
        put_val(out, R3_LEN + kind, v.L - RR_MINL);
        if (kind != K_SELF) r3_push(cache, &nc, r3_diag(v.dir, v.p, o, v.L));
        o += v.L; prevk = kind;
    }
}

// ---------------------------------------------------------------- tables and rANS encoding
static void norm_table(const uint64_t* cnt, int n, uint16_t* f) {           // sum = R3_M, every seen symbol >= 1
    uint64_t tot = 0; for (int s = 0; s < n; s++) tot += cnt[s];
    for (int s = 0; s < n; s++) f[s] = 0; if (!tot) return;
    int64_t sum = 0, bi = 0; for (int s = 0; s < n; s++) { if (!cnt[s]) continue; uint64_t v = cnt[s] * R3_M / tot; if (!v) v = 1; f[s] = (uint16_t)v; sum += v; if (cnt[s] > cnt[bi]) bi = s; }
    while (sum != R3_M) { if (sum < (int64_t)R3_M) { f[bi]++; sum++; } else { int big = -1; for (int s = 0; s < n; s++) if (f[s] > 1 && (big < 0 || f[s] > f[big])) big = s; f[big]--; sum--; } }
}
static void build_tab(R3Tab& T) { for (int c = 0; c < R3_NCTX; c++) { uint32_t a = 0; for (int s = 0; s < R3_AB; s++) { T.cum[c][s] = (uint16_t)a; for (uint32_t k = 0; k < T.freq[c][s]; k++) T.sym[c][a + k] = (uint8_t)s; a += T.freq[c][s]; } T.cum[c][R3_AB] = (uint16_t)a; } }
static std::vector<uint8_t> rans_encode(const std::vector<Sym>& syms, const R3Tab& T) {
    std::vector<uint8_t> buf(syms.size() * 8 + 64); size_t w = buf.size(); uint32_t x = R3_L;
    for (size_t q = syms.size(); q-- > 0;) { const Sym& s = syms[q];
        if (s.ctx == 0xFFFF) { uint32_t nb = s.nb; int parts = (nb + 15) / 16; uint32_t ks[4]; uint64_t raw = s.raw;      // decoder reads low 16 first
            for (int k = 0; k < parts; k++) { ks[k] = nb > 16 ? 16 : nb; nb -= ks[k]; }
            uint32_t shs[4]; uint32_t sh = 0; for (int k = 0; k < parts; k++) { shs[k] = sh; sh += ks[k]; }
            for (int k = parts - 1; k >= 0; k--) { const uint32_t kb = ks[k]; const uint32_t b = (uint32_t)((raw >> shs[k]) & ((1ull << kb) - 1));
                const uint32_t xmax = ((R3_L >> kb) << 8); while (x >= xmax) { buf[--w] = (uint8_t)x; x >>= 8; } x = (x << kb) + b; } }
        else { const uint32_t f = T.freq[s.ctx][s.s], c = T.cum[s.ctx][s.s];
            const uint32_t xmax = ((R3_L >> R3_PB) << 8) * f; while (x >= xmax) { buf[--w] = (uint8_t)x; x >>= 8; }
            x = ((x / f) << R3_PB) + (x % f) + c; } }
    buf[--w] = (uint8_t)(x >> 16); buf[--w] = (uint8_t)(x >> 8); buf[--w] = (uint8_t)x;
    return std::vector<uint8_t>(buf.begin() + w, buf.end());
}

static void encode3_one(const std::vector<uint8_t>& R, const Index& I, int T, const char* fa, const std::string& dir);
static int cmd_build3(int argc, char** argv) {
    const std::string dir = argv[3]; const int T = atoi(argv[4]);
    Fasta RF = read_fasta(argv[2]); std::vector<uint8_t> R = upper(RF.b); RF.b.clear(); RF.b.shrink_to_fit(); Index I = build_index(R, T);
    for (int a = 5; a < argc; a++) encode3_one(R, I, T, argv[a], dir);
    return 0;
}
static void encode3_one(const std::vector<uint8_t>& R, const Index& I, int T, const char* fa, const std::string& dir) {
    {
        Fasta F = read_fasta(fa); const std::vector<uint8_t> A = upper(F.b); const double s1 = now_s();
        const uint64_t nb = (A.size() + RR_BS - 1) / RR_BS;
        std::vector<std::vector<Ev>> ev(nb); std::vector<R3Diag> st(nb), fin(nb);
        for (auto& g : st) { g.c = 0; g.dir = 0; }
        auto pass = [&] { std::atomic<uint64_t> next{0}; std::vector<std::thread> th;
            for (int t = 0; t < T; t++) th.emplace_back([&] { for (;;) { const uint64_t b = next.fetch_add(1); if (b >= nb) break; ev[b].clear();
                fin[b] = parse_block(A.data(), b * RR_BS, std::min<uint64_t>(A.size(), (b + 1) * RR_BS), R, I, st[b], ev[b]); } });
            for (auto& x : th) x.join(); };
        pass();                                                          // carry: start each block on the previous block's last diagonal
        for (uint64_t b = 1; b < nb; b++) { st[b] = fin[b - 1]; st[b].c = fin[b - 1].dir ? st[b].c - RR_BS : st[b].c + RR_BS; }
        pass();
        const double s2 = now_s();
        if (const char* dp = getenv("RR3_DUMP")) {                       // 3b: literal runs >= 64 bases -> FASTA records (appended)
            FILE* df = fopen(dp, "ab"); uint64_t nd = 0, bd = 0;
            for (uint64_t b = 0; b < nb; b++) { const uint64_t bs = b * RR_BS; const uint32_t blen = (uint32_t)std::min<uint64_t>(RR_BS, A.size() - bs); uint32_t o = 0;
                auto dump = [&](uint32_t x, uint32_t y) { if (y - x < 64) return; fprintf(df, ">%s_%llu_%u\n", base(fa).c_str(), (unsigned long long)b, x);
                    for (uint32_t q = x; q < y; q += 80) { fwrite(&A[bs + q], 1, std::min<uint32_t>(80, y - q), df); fputc('\n', df); } nd++; bd += y - x; };
                for (auto& e : ev[b]) { dump(o, e.at); o = e.at + e.L; } dump(o, blen); }
            fclose(df); printf("RR3DUMP\t%s\t%llu runs\t%llu bases\n", base(fa).c_str(), (unsigned long long)nd, (unsigned long long)bd);
        }
        std::vector<std::vector<Sym>> sy(nb);
        { std::atomic<uint64_t> next{0}; std::vector<std::thread> th; for (int t = 0; t < T; t++) th.emplace_back([&] { for (;;) { const uint64_t b = next.fetch_add(1); if (b >= nb) break;
            symbols(A.data(), b * RR_BS, (uint32_t)std::min<uint64_t>(RR_BS, A.size() - b * RR_BS), ev[b], R, st[b], sy[b]); } }); for (auto& x : th) x.join(); }
        if (getenv("RR3_ABSSTAT")) { const char* nmw[5] = {"-", "same strand, current", "other strand, current", "same strand, older", "other strand, older"};
            for (int h = 1; h < 5; h++) { printf("ABSSTAT %s:", nmw[h]); for (int l = 0; l < 65; l++) if (g_absstat[h][l]) printf(" 2^%d:%llu", l, (unsigned long long)g_absstat[h][l]); printf("\n"); } memset(g_absstat, 0, sizeof g_absstat); }
        static uint64_t cnt[R3_NCTX][R3_AB]; memset(cnt, 0, sizeof cnt); uint64_t raw_bits = 0, nsym = 0;
        for (auto& v : sy) for (auto& s : v) { if (s.ctx == 0xFFFF) raw_bits += s.nb; else { cnt[s.ctx][s.s]++; nsym++; } }
        static R3Tab TB; memset(&TB, 0, sizeof TB); for (int c = 0; c < R3_NCTX; c++) norm_table(cnt[c], R3_ALPHA[c], TB.freq[c]); build_tab(TB);
        // ideal bits per context group (for the report)
        double cbits[R3_NCTX] = {0}; for (int c = 0; c < R3_NCTX; c++) for (int s = 0; s < R3_AB; s++) if (cnt[c][s]) cbits[c] += cnt[c][s] * (R3_PB - std::log2((double)TB.freq[c][s]));
        std::vector<std::vector<uint8_t>> enc(nb);
        { std::atomic<uint64_t> next{0}; std::vector<std::thread> th; for (int t = 0; t < T; t++) th.emplace_back([&] { for (;;) { const uint64_t b = next.fetch_add(1); if (b >= nb) break; enc[b] = rans_encode(sy[b], TB); } }); for (auto& x : th) x.join(); }
        const double s3 = now_s();
        std::vector<uint8_t> P, M; for (auto& v : enc) P.insert(P.end(), v.begin(), v.end());
        auto p64 = [&](uint64_t v) { M.insert(M.end(), (uint8_t*)&v, (uint8_t*)&v + 8); }; auto p32 = [&](uint32_t v) { M.insert(M.end(), (uint8_t*)&v, (uint8_t*)&v + 4); };
        M.insert(M.end(), (const uint8_t*)"RRMETA3", (const uint8_t*)"RRMETA3" + 8); p64(A.size()); p32((uint32_t)F.rec.size());
        for (auto& r : F.rec) { p32((uint32_t)r.hdr.size()); M.insert(M.end(), r.hdr.begin(), r.hdr.end()); p64(r.len); p32(r.lw); }
        std::vector<uint8_t> runs; uint64_t nr = 0, last = 0;
        for (uint64_t i = 0; i < F.b.size();) { if (F.b[i] >= 'a' && F.b[i] <= 'z') { uint64_t j = i; while (j < F.b.size() && F.b[j] >= 'a' && F.b[j] <= 'z') j++; put_leb(runs, i - last); put_leb(runs, j - i); last = j; nr++; i = j; } else i++; }
        p64(nr); M.insert(M.end(), runs.begin(), runs.end());
        const size_t mt0 = M.size(); for (int c = 0; c < R3_NCTX; c++) for (int s = 0; s < R3_ALPHA[c]; s++) put_leb(M, TB.freq[c][s]); const size_t mtab = M.size() - mt0;
        p64(nb); uint64_t prevc = 0; uint32_t prevd = 0; const size_t mb0 = M.size();
        for (uint64_t b = 0; b < nb; b++) { put_leb(M, enc[b].size());
            const int64_t pred = b == 0 ? 0 : (int64_t)(prevd ? prevc - RR_BS : prevc + RR_BS); put_leb(M, zz((int64_t)st[b].c - pred) * 2 + st[b].dir); prevc = st[b].c; prevd = st[b].dir; }
        const size_t mblk = M.size() - mb0;
        std::vector<uint8_t> Z(ZSTD_compressBound(M.size())); const size_t zn = ZSTD_compress(Z.data(), Z.size(), M.data(), M.size(), 19);
        const std::string nm = dir + "/" + base(fa); spit(nm + ".r3", P.data(), P.size()); spit(nm + ".meta3.zst", Z.data(), zn);
        uint64_t kinds[6] = {0}, lits = 0; for (auto& v : ev) for (auto& e : v) { (void)e; } for (auto& v : sy) for (auto& s : v) { if (s.ctx >= R3_KIND && s.ctx < R3_KIND + 16) kinds[s.s]++; if (s.ctx >= R3_LITR && s.ctx < R3_KIND) lits++; }
        auto grp = [&](int a0, int a1) { double t = 0; for (int c = a0; c < a1; c++) t += cbits[c]; return t / 8e6; };
        printf("RR3BUILD\t%s\tparse %.2f s\tcode %.2f s\tblocks %llu\tpayload %zu\tmeta raw %zu (tables %zu, blocks %zu) zst %zu\ttotal %zu\tkinds cont %llu delta %llu rep %llu abs %llu self %llu flip %llu\tliterals %llu\t"
               "MB: LL %.2f LIT %.2f KIND %.2f DELTA %.2f REP %.2f DIR %.2f SELF %.2f LEN %.2f raw-bits %.2f\n",
               base(fa).c_str(), s2 - s1, s3 - s2, (unsigned long long)nb, P.size(), M.size(), mtab, mblk, zn, P.size() + zn,
               (unsigned long long)kinds[0], (unsigned long long)kinds[1], (unsigned long long)kinds[2], (unsigned long long)kinds[3], (unsigned long long)kinds[4], (unsigned long long)kinds[5], (unsigned long long)lits,
               grp(R3_LL, R3_LITR), grp(R3_LITR, R3_KIND), grp(R3_KIND, R3_DELTA), grp(R3_DELTA, R3_REPK), grp(R3_REPK, R3_DIR), grp(R3_DIR, R3_SELF), grp(R3_SELF, R3_LEN), grp(R3_LEN, R3_NCTX), raw_bits / 8e6);
        fflush(stdout);
    }
}

struct Arch3 { Meta M; R3Tab* T = nullptr; std::vector<uint8_t> P; std::vector<uint64_t> off; std::vector<R3Diag> st; };
static Arch3 load3(const std::string& nm) {
    Arch3 X; std::vector<uint8_t> z = slurp(nm + ".meta3.zst"); const unsigned long long mn = ZSTD_getFrameContentSize(z.data(), z.size());
    std::vector<uint8_t> M((size_t)mn); if (ZSTD_decompress(M.data(), M.size(), z.data(), z.size()) != mn) { fprintf(stderr, "meta3\n"); exit(2); }
    size_t i = 8; auto g64 = [&] { uint64_t v; memcpy(&v, &M[i], 8); i += 8; return v; }; auto g32 = [&] { uint32_t v; memcpy(&v, &M[i], 4); i += 4; return v; };
    auto gl = [&] { uint64_t v = 0; int sh = 0; for (;;) { uint8_t c = M[i++]; v |= (uint64_t)(c & 0x7F) << sh; if (!(c & 0x80)) break; sh += 7; } return v; };
    X.M.n = g64(); const uint32_t nr = g32(); uint64_t bo = 0;
    for (uint32_t r = 0; r < nr; r++) { Rec q; const uint32_t hl = g32(); q.hdr.assign((const char*)&M[i], hl); i += hl; q.len = g64(); q.lw = g32(); q.boff = bo; bo += q.len; q.foff = 0; X.M.rec.push_back(q); }
    const uint64_t nl = g64(); uint64_t last = 0; for (uint64_t k = 0; k < nl; k++) { const uint64_t g = gl(), l = gl(); X.M.low.push_back({last + g, l}); last += g + l; }
    X.T = new R3Tab(); memset(X.T, 0, sizeof(R3Tab)); for (int c = 0; c < R3_NCTX; c++) for (int s = 0; s < R3_ALPHA[c]; s++) X.T->freq[c][s] = (uint16_t)gl(); build_tab(*X.T);
    X.M.nb = g64(); X.off.assign(X.M.nb + 1, 0); X.st.resize(X.M.nb); uint64_t prevc = 0; uint32_t prevd = 0;
    for (uint64_t b = 0; b < X.M.nb; b++) { X.off[b + 1] = X.off[b] + gl(); const uint64_t v = gl(); const int64_t pred = b == 0 ? 0 : (int64_t)(prevd ? prevc - RR_BS : prevc + RR_BS);
        const uint64_t q = v >> 1; X.st[b].dir = (uint32_t)(v & 1); X.st[b].c = (uint64_t)(pred + ((int64_t)(q >> 1) ^ -(int64_t)(q & 1))); prevc = X.st[b].c; prevd = X.st[b].dir; }
    X.P = slurp(nm + ".r3");
    return X;
}
static bool rr3_window(const Arch3& X, const std::vector<uint8_t>& R, uint64_t s, uint64_t W, uint8_t* out, std::vector<RrOp>& ops, uint8_t* blk, uint8_t* lit) {
    const uint64_t b0 = s / RR_BS, b1 = (s + W - 1) / RR_BS;
    for (uint64_t b = b0; b <= b1; b++) {
        const uint64_t bst = b * RR_BS; const uint32_t blen = (uint32_t)std::min<uint64_t>(RR_BS, X.M.n - bst);
        const int n = r3_decode_block(&X.P[X.off[b]], (uint32_t)(X.off[b + 1] - X.off[b]), X.T, R.data(), R.size(), blen, X.st[b], ops.data(), RR_MAXOPS, lit, RR_BS);
        if (n < 0) return false;
        exec_fast(ops.data(), n, lit, R.data(), blk);
        const uint64_t a = std::max(s, bst), e = std::min(s + W, bst + blen); memcpy(out + (a - s), blk + (a - bst), e - a);
    }
    if (!X.M.low.empty()) { auto it = std::upper_bound(X.M.low.begin(), X.M.low.end(), std::make_pair(s, (uint64_t)~0ull)); if (it != X.M.low.begin()) --it;
        for (; it != X.M.low.end() && it->first < s + W; ++it) { const uint64_t a = std::max(s, it->first), e = std::min(s + W, it->first + it->second); for (uint64_t x = a; x < e; x++) out[x - s] |= 0x20; } }
    return true;
}
static bool full3_string(const std::vector<uint8_t>& R, const std::string& nm, std::string& o) {
    Arch3 X = load3(nm); std::vector<uint8_t> A(X.M.n + 64), blk(RR_BS), lit(RR_BS); std::vector<RrOp> ops(RR_MAXOPS); bool ok = true;
    for (uint64_t s = 0; s < X.M.n && ok; s += 1u << 20) { const uint64_t W = std::min<uint64_t>(1u << 20, X.M.n - s); ok = rr3_window(X, R, s, W, &A[s], ops, blk.data(), lit.data()); }
    delete X.T; if (!ok) return false;
    o.clear(); o.reserve(X.M.n + X.M.n / 60 + 1024);
    for (auto& r : X.M.rec) { o += '>'; o += r.hdr; o += '\n'; for (uint64_t x = 0; x < r.len; x += r.lw) { o.append((const char*)&A[r.boff + x], std::min<uint64_t>(r.lw, r.len - x)); o += '\n'; } }
    return true;
}
static uint64_t fsize(const std::string& p) { struct stat st; return stat(p.c_str(), &st) ? 0 : (uint64_t)st.st_size; }
// both formats for one assembly: v1+carry (refrel2, one token stream + literals through the CLI) and refrel3; each
// decoded back in full and compared with the FASTA; one line RRBOTH
static int cmd_both(int argc, char** argv) {
    const std::string dir = argv[3]; const int T = atoi(argv[4]); const std::string cli = argv[5];
    const double t0 = now_s(); Fasta RF = read_fasta(argv[2]); std::vector<uint8_t> R = upper(RF.b); RF.b.clear(); RF.b.shrink_to_fit(); Index I = build_index(R, T); const double t1 = now_s();
    int bad = 0;
    for (int a = 6; a < argc; a++) {
        const std::string fa = argv[a], nm = dir + "/" + base(argv[a]);
        const double e0 = now_s(); encode2_one(R, I, T, false, true, argv[a], dir);
        for (const char* sfx : {".t0", ".lit"}) { const std::string c = "env -i PATH=\"$PATH\" ACEAPEX_BS=16384 LIT_CHUNK=65536 AX_PROFILE=open " + cli + " c --in " + nm + sfx + " --out " + nm + sfx + ".aet --threads " + std::to_string(T) + " >/dev/null 2>&1";
            if (system(c.c_str()) != 0) { printf("CLI failed for %s%s\n", nm.c_str(), sfx); bad++; } unlink((nm + sfx).c_str()); }
        const double e1 = now_s(); encode3_one(R, I, T, argv[a], dir); const double e2 = now_s();
        const std::vector<uint8_t> F = slurp(fa); std::string o; bool ok2 = full2_string(R, nm, o) && o.size() == F.size() && !memcmp(o.data(), F.data(), F.size());
        bool ok3 = full3_string(R, nm, o) && o.size() == F.size() && !memcmp(o.data(), F.data(), F.size()); const double e3 = now_s();
        const uint64_t s2 = fsize(nm + ".t0.aet") + fsize(nm + ".lit.aet") + fsize(nm + ".meta2.zst"), s3 = fsize(nm + ".r3") + fsize(nm + ".meta3.zst");
        printf("RRBOTH\t%s\t%zu\tv1carry %llu\trefrel3 %llu\tenc v1carry %.1f s\tenc refrel3 %.1f s\tcheck %.1f s\tref load %.1f s\t%s\n", base(argv[a]).c_str(), F.size(),
               (unsigned long long)s2, (unsigned long long)s3, e1 - e0, e2 - e1, e3 - e2, t1 - t0, ok2 && ok3 ? "both == FASTA" : (ok2 ? "REFREL3 DIFFERS" : (ok3 ? "V1CARRY DIFFERS" : "BOTH DIFFER"))); fflush(stdout);
        if (!ok2 || !ok3) bad++;
    }
    return bad ? 5 : 0;
}
static int cmd_full3(char** argv) {
    Fasta RF = read_fasta(argv[2]); std::vector<uint8_t> R = upper(RF.b); RF.b.clear();
    const double t0 = now_s(); Arch3 X = load3(argv[3]); std::vector<uint8_t> A(X.M.n + 64), blk(RR_BS), lit(RR_BS); std::vector<RrOp> ops(RR_MAXOPS);
    for (uint64_t s = 0; s < X.M.n; s += 1u << 20) { const uint64_t W = std::min<uint64_t>(1u << 20, X.M.n - s); if (!rr3_window(X, R, s, W, &A[s], ops, blk.data(), lit.data())) { fprintf(stderr, "decode failed at %llu\n", (unsigned long long)s); return 4; } }
    std::string o; o.reserve(X.M.n + X.M.n / 60 + 1024);
    for (auto& r : X.M.rec) { o += '>'; o += r.hdr; o += '\n'; for (uint64_t x = 0; x < r.len; x += r.lw) { o.append((const char*)&A[r.boff + x], std::min<uint64_t>(r.lw, r.len - x)); o += '\n'; } }
    spit(argv[4], o.data(), o.size()); printf("[full3] %s: %zu bytes in %.1f s\n", argv[3], o.size(), now_s() - t0); return 0;
}
static int cmd_windows3(int argc, char** argv) {
    Fasta RF = read_fasta(argv[2]); std::vector<uint8_t> R = upper(RF.b); RF.b.clear(); RF.b.shrink_to_fit();
    Arch3 X = load3(argv[3]); Fasta F = read_fasta(argv[4]); const int T = atoi(argv[5]); const uint64_t seed = argc > 6 ? strtoull(argv[6], 0, 10) : 20261003;
    for (uint64_t W = 256; W <= (1u << 20); W *= 4) {
        const uint64_t n = std::min<uint64_t>(20000, std::max<uint64_t>(256, (1ull << 31) / W)); std::mt19937_64 g(seed + W); std::vector<uint64_t> off(n); for (auto& x : off) x = g() % (X.M.n - W + 1);
        std::atomic<uint64_t> next{0}; std::atomic<int> bad{0}; const double t0 = now_s(); std::vector<std::thread> th;
        for (int t = 0; t < T; t++) th.emplace_back([&] { std::vector<uint8_t> out(W + 64), blk(RR_BS), lit(RR_BS); std::vector<RrOp> ops(RR_MAXOPS);
            for (;;) { const uint64_t q = next.fetch_add(1); if (q >= n) break; if (!rr3_window(X, R, off[q], W, out.data(), ops, blk.data(), lit.data()) || memcmp(out.data(), &F.b[off[q]], W)) bad++; } });
        for (auto& x : th) x.join(); const double dt = now_s() - t0;
        printf("RR3WIN\t%llu\t%llu\t%d\t%.0f\t%.3f\t%s\n", (unsigned long long)W, (unsigned long long)n, T, n / dt, n * W / dt / 1e9, bad ? "DIFFERS" : "ok"); fflush(stdout);
    }
    return 0;
}
#ifndef RR3_NO_MAIN
int main(int argc, char** argv) {
    for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
    if (argc >= 6 && !strcmp(argv[1], "build")) return cmd_build3(argc, argv);
    if (argc >= 7 && !strcmp(argv[1], "both")) return cmd_both(argc, argv);
    if (argc >= 5 && !strcmp(argv[1], "full")) return cmd_full3(argv);
    if (argc >= 6 && !strcmp(argv[1], "windows")) return cmd_windows3(argc, argv);
    fprintf(stderr, "usage: refrel3 build <ref.fa> <dir> <threads> <asm.fa>... | full <ref.fa> <dir/name> <out.fa> | windows <ref.fa> <dir/name> <asm.fa> <threads> [seed]\n");
    return 1;
}
#endif
