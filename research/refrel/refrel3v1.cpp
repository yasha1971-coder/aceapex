// refrel3v1.cpp - the refrel3 v1 container (FORMAT.md): one file per assembly, block size Q in the header
// (1024 / 2048 / 4096 / 16384), the decoded reference named and pinned by SHA-256, header XXH3 (mandatory), XXH3 per
// block (flag), XXH3 of the source FASTA, contig table for fetch by coordinates. Entropy coding = refrel3 (refrel3.h).
//   encode  <ref.fa> <Q> <threads> <asm.fa> <out.rr3> [nohash]
//   decode  <ref.fa> <in.rr3> <out.fa>                       full decode, all hashes checked
//   fetch   <ref.fa> <in.rr3> <name:start-end>...            1-based inclusive, FASTA-like output
//   info    <in.rr3>
//   recode  <ref.fa> <threads> <jobs.tsv> <outdir>           old refrel3 archives -> FASTA in memory -> q4k + q16k v1, each
//           decoded back and compared by XXH3 with the source; one manifest line per assembly on stdout
//   corrupt <ref.fa> <in.rr3> <cases per kind> <verify 0|1> <seed> <parallel>   6 kinds, a process per case, 10 s watchdog
// Build: g++ -std=c++17 -O3 -march=native -funroll-loops -Isrc -Iresearch/refrel research/refrel/refrel3v1.cpp src/aceapex_api.cpp -lzstd -lpthread
#define RR3_NO_MAIN
#include "refrel3.cpp"
#include "rr_sha256.h"
#define XXH_INLINE_ALL
#include "xxhash.h"
#include <signal.h>
#include <sys/wait.h>
#include <poll.h>

static const char V1_MAGIC[8] = {'R', 'F', 'R', 'L', '3', 'V', '1', 0};
static const uint32_t V1_VERSION = 1, V1_HDR = 136, F_BLOCKHASH = 1;
static bool q_ok(uint32_t q) { return q == 1024 || q == 2048 || q == 4096 || q == 16384; }
static uint64_t rd64(const uint8_t* p) { uint64_t v; memcpy(&v, p, 8); return v; }
static uint32_t rd32(const uint8_t* p) { uint32_t v; memcpy(&v, p, 4); return v; }
static void put64(std::vector<uint8_t>& o, size_t at, uint64_t v) { memcpy(&o[at], &v, 8); }
static void put32(std::vector<uint8_t>& o, size_t at, uint32_t v) { memcpy(&o[at], &v, 4); }
static std::string hex(const uint8_t* p, size_t n) { static const char* d = "0123456789abcdef"; std::string s; for (size_t i = 0; i < n; i++) { s += d[p[i] >> 4]; s += d[p[i] & 15]; } return s; }

struct Ref { std::vector<uint8_t> R; uint8_t sha[32]; std::string name; Index I; };
static Ref load_ref(const char* path, int T, bool index) {
    Ref r; Fasta F = read_fasta(path); r.R = upper(F.b); rr_sha256(r.R.data(), r.R.size(), r.sha);
    r.name = path; const size_t s = r.name.find_last_of('/'); if (s != std::string::npos) r.name = r.name.substr(s + 1);
    if (index) r.I = build_index(r.R, T);
    return r;
}

// ---------------------------------------------------------------- encode
static std::vector<uint8_t> encode_v1(const Ref& ref, const std::vector<uint8_t>& fasta, uint32_t Q, int T, bool blockhash) {
    Fasta F = parse_fasta(fasta, "input"); const std::vector<uint8_t> A = upper(F.b);
    const uint64_t nb = (A.size() + Q - 1) / Q;
    std::vector<std::vector<Ev>> ev(nb); std::vector<R3Diag> st(nb), fin(nb); for (auto& g : st) { g.c = 0; g.dir = 0; }
    auto par = [&](auto&& f) { std::atomic<uint64_t> next{0}; std::vector<std::thread> th; for (int t = 0; t < T; t++) th.emplace_back([&] { for (;;) { const uint64_t b = next.fetch_add(1); if (b >= nb) break; f(b); } }); for (auto& x : th) x.join(); };
    auto pass = [&] { par([&](uint64_t b) { ev[b].clear(); fin[b] = parse_block(A.data(), b * Q, std::min<uint64_t>(A.size(), (b + 1) * Q), ref.R, ref.I, st[b], ev[b]); }); };
    pass(); for (uint64_t b = 1; b < nb; b++) { st[b] = fin[b - 1]; st[b].c = fin[b - 1].dir ? st[b].c - Q : st[b].c + Q; } pass();
    std::vector<std::vector<Sym>> sy(nb); par([&](uint64_t b) { symbols(A.data(), b * Q, (uint32_t)std::min<uint64_t>(Q, A.size() - b * Q), ev[b], ref.R, st[b], sy[b]); });
    std::vector<uint64_t> cnt((size_t)R3_NCTX * R3_AB, 0); for (auto& v : sy) for (auto& s : v) if (s.ctx != 0xFFFF) cnt[(size_t)s.ctx * R3_AB + s.s]++;
    R3Tab* TB = new R3Tab(); memset(TB, 0, sizeof(R3Tab)); for (int c = 0; c < R3_NCTX; c++) norm_table(&cnt[(size_t)c * R3_AB], R3_ALPHA[c], TB->freq[c]); build_tab(*TB);
    std::vector<std::vector<uint8_t>> enc(nb); par([&](uint64_t b) { enc[b] = rans_encode(sy[b], *TB); });
    std::vector<uint8_t> M;                                                    // meta, raw
    auto m64 = [&](uint64_t v) { M.insert(M.end(), (uint8_t*)&v, (uint8_t*)&v + 8); }; auto m32 = [&](uint32_t v) { M.insert(M.end(), (uint8_t*)&v, (uint8_t*)&v + 4); };
    m32((uint32_t)F.rec.size()); for (auto& r : F.rec) { m32((uint32_t)r.hdr.size()); M.insert(M.end(), r.hdr.begin(), r.hdr.end()); m64(r.len); m32(r.lw); }
    std::vector<uint8_t> runs; uint64_t nr = 0, last = 0;
    for (uint64_t i = 0; i < F.b.size();) { if (F.b[i] >= 'a' && F.b[i] <= 'z') { uint64_t j = i; while (j < F.b.size() && F.b[j] >= 'a' && F.b[j] <= 'z') j++; put_leb(runs, i - last); put_leb(runs, j - i); last = j; nr++; i = j; } else i++; }
    m64(nr); M.insert(M.end(), runs.begin(), runs.end());
    for (int c = 0; c < R3_NCTX; c++) for (int s = 0; s < R3_ALPHA[c]; s++) put_leb(M, TB->freq[c][s]);
    uint64_t prevc = 0; uint32_t prevd = 0;
    for (uint64_t b = 0; b < nb; b++) { put_leb(M, enc[b].size()); const int64_t pred = b == 0 ? 0 : (int64_t)(prevd ? prevc - Q : prevc + Q); put_leb(M, zz((int64_t)st[b].c - pred) * 2 + st[b].dir); prevc = st[b].c; prevd = st[b].dir; }
    std::vector<uint8_t> MZ(ZSTD_compressBound(M.size())); MZ.resize(ZSTD_compress(MZ.data(), MZ.size(), M.data(), M.size(), 19));
    std::vector<uint8_t> H; if (blockhash) { H.resize(nb * 8); for (uint64_t b = 0; b < nb; b++) { const uint64_t h = XXH3_64bits(&A[b * Q], std::min<uint64_t>(Q, A.size() - b * Q)); memcpy(&H[b * 8], &h, 8); } }
    uint64_t PL = 0; for (auto& v : enc) PL += v.size();
    std::vector<uint8_t> o(V1_HDR, 0);
    memcpy(&o[0], V1_MAGIC, 8); put32(o, 8, V1_VERSION); put32(o, 12, Q); put32(o, 16, blockhash ? F_BLOCKHASH : 0); put32(o, 20, 0);
    memcpy(&o[24], ref.sha, 32); put64(o, 56, ref.R.size()); put64(o, 64, A.size()); put64(o, 72, nb);
    put64(o, 80, XXH3_64bits(fasta.data(), fasta.size())); put64(o, 88, XXH3_64bits(F.b.data(), F.b.size()));
    put64(o, 96, MZ.size()); put64(o, 104, M.size()); put64(o, 112, H.size()); put64(o, 120, PL);
    const uint16_t nl = (uint16_t)std::min<size_t>(ref.name.size(), 65535); o.push_back((uint8_t)nl); o.push_back((uint8_t)(nl >> 8)); o.insert(o.end(), ref.name.begin(), ref.name.begin() + nl);
    o.insert(o.end(), MZ.begin(), MZ.end()); o.insert(o.end(), H.begin(), H.end());
    put64(o, 128, XXH3_64bits(o.data(), o.size()));                           // header XXH3: [0, payload) with this field 0
    for (auto& v : enc) o.insert(o.end(), v.begin(), v.end());
    delete TB; return o;
}

// ---------------------------------------------------------------- open (every check before any decode)
struct V1 { const uint8_t* a = nullptr; size_t n = 0; uint32_t Q = 0, flags = 0; uint64_t nbases = 0, nb = 0, fasta_xxh = 0, bases_xxh = 0;
    std::string refname; std::vector<Rec> rec; std::vector<std::pair<uint64_t, uint64_t>> low; R3Tab* T = nullptr; std::vector<uint64_t> off; std::vector<R3Diag> st;
    const uint8_t* hashes = nullptr; const uint8_t* P = nullptr; ~V1() { delete T; } };
static int open_v1(const uint8_t* a, size_t n, const Ref& ref, V1& X, std::string& why) {
    auto fail = [&](const char* w) { why = w; return 1; };
    if (n < V1_HDR + 2) return fail("short file");
    if (memcmp(a, V1_MAGIC, 8)) return fail("magic");
    if (rd32(a + 8) != V1_VERSION) return fail("version");
    X.Q = rd32(a + 12); if (!q_ok(X.Q)) return fail("block size");
    X.flags = rd32(a + 16); if (X.flags & ~F_BLOCKHASH) return fail("unknown flags"); if (rd32(a + 20)) return fail("reserved");
    X.nbases = rd64(a + 64); X.nb = rd64(a + 72); X.fasta_xxh = rd64(a + 80); X.bases_xxh = rd64(a + 88);
    const uint64_t mz = rd64(a + 96), mr = rd64(a + 104), hs = rd64(a + 112), pl = rd64(a + 120);
    const uint16_t nl = (uint16_t)(a[136] | a[137] << 8);
    const uint64_t pstart = (uint64_t)V1_HDR + 2 + nl + mz + hs;
    if (mz > n || hs > n || pl > n || pstart > n || pstart + pl != n) return fail("section sizes");
    if (X.nb != (X.nbases + X.Q - 1) / X.Q || (X.nbases && !X.nb)) return fail("block count");
    if (hs != ((X.flags & F_BLOCKHASH) ? X.nb * 8 : 0)) return fail("hash section size");
    { std::vector<uint8_t> h(a, a + pstart); memset(&h[128], 0, 8); if (XXH3_64bits(h.data(), h.size()) != rd64(a + 128)) return fail("header XXH3"); }
    if (memcmp(a + 24, ref.sha, 32) || rd64(a + 56) != ref.R.size()) return fail("reference SHA-256 / size differs");
    X.refname.assign((const char*)a + 138, nl);
    const uint8_t* mzp = a + V1_HDR + 2 + nl;
    if (mr > (1ull << 32) || ZSTD_getFrameContentSize(mzp, mz) != mr) return fail("meta frame");
    std::vector<uint8_t> M(mr); if (ZSTD_decompress(M.data(), mr, mzp, mz) != mr) return fail("meta decompress");
    size_t i = 0; bool bad = false;
    auto need = [&](size_t k) { if (i + k > M.size()) { bad = true; return false; } return true; };
    auto g64 = [&]() -> uint64_t { if (!need(8)) return 0; uint64_t v; memcpy(&v, &M[i], 8); i += 8; return v; };
    auto g32 = [&]() -> uint32_t { if (!need(4)) return 0; uint32_t v; memcpy(&v, &M[i], 4); i += 4; return v; };
    auto gl = [&]() -> uint64_t { uint64_t v = 0; int sh = 0; for (;;) { if (!need(1) || sh > 63) { bad = true; return 0; } uint8_t c = M[i++]; v |= (uint64_t)(c & 0x7F) << sh; if (!(c & 0x80)) break; sh += 7; } return v; };
    const uint32_t nr = g32(); uint64_t bo = 0; if (nr > M.size()) return fail("records");
    for (uint32_t r = 0; r < nr && !bad; r++) { Rec q; const uint32_t hl = g32(); if (!need(hl)) break; q.hdr.assign((const char*)&M[i], hl); i += hl; q.len = g64(); q.lw = g32(); if (!q.lw && q.len) bad = true; q.boff = bo; bo += q.len; q.foff = 0; X.rec.push_back(q); }
    if (bad || bo != X.nbases) return fail("contig table");
    const uint64_t nlw = g64(); uint64_t lst = 0; if (nlw > X.nbases) return fail("case runs");
    for (uint64_t k = 0; k < nlw && !bad; k++) { const uint64_t g = gl(), l = gl(); if (lst + g + l > X.nbases) { bad = true; break; } X.low.push_back({lst + g, l}); lst += g + l; }
    if (bad) return fail("case runs");
    X.T = new R3Tab(); memset(X.T, 0, sizeof(R3Tab));
    for (int c = 0; c < R3_NCTX && !bad; c++) { uint64_t sum = 0; for (int s = 0; s < R3_ALPHA[c]; s++) { const uint64_t f = gl(); if (f > R3_M) bad = true; X.T->freq[c][s] = (uint16_t)f; sum += f; } if (sum && sum != R3_M) bad = true; }
    if (bad) return fail("model tables");
    build_tab(*X.T);
    X.off.assign(X.nb + 1, 0); X.st.resize(X.nb); uint64_t prevc = 0; uint32_t prevd = 0;
    for (uint64_t b = 0; b < X.nb && !bad; b++) { const uint64_t len = gl(); X.off[b + 1] = X.off[b] + len; const uint64_t v = gl();
        const int64_t pred = b == 0 ? 0 : (int64_t)(prevd ? prevc - X.Q : prevc + X.Q); const uint64_t q = v >> 1;
        X.st[b].dir = (uint32_t)(v & 1); X.st[b].c = (uint64_t)(pred + ((int64_t)(q >> 1) ^ -(int64_t)(q & 1))); prevc = X.st[b].c; prevd = X.st[b].dir; }
    if (bad || i != M.size() || X.off[X.nb] != pl) return fail("block table");
    X.a = a; X.n = n; X.hashes = (X.flags & F_BLOCKHASH) ? a + V1_HDR + 2 + nl + mz : nullptr; X.P = a + pstart;
    return 0;
}
// block b (upper case) into out; 0 ok, 1 decode error, 2 block hash mismatch
static int block_v1(const V1& X, const Ref& ref, uint64_t b, uint8_t* out, std::vector<RrOp>& ops, std::vector<uint8_t>& lit, bool verify) {
    const uint32_t blen = (uint32_t)std::min<uint64_t>(X.Q, X.nbases - b * X.Q);
    const int k = r3_decode_block(X.P + X.off[b], (uint32_t)(X.off[b + 1] - X.off[b]), X.T, ref.R.data(), ref.R.size(), blen, X.st[b], ops.data(), (uint32_t)ops.size(), lit.data(), (uint32_t)lit.size());
    if (k < 0) return 1;
    exec_fast(ops.data(), k, lit.data(), ref.R.data(), out);
    if (verify && X.hashes && XXH3_64bits(out, blen) != rd64(X.hashes + 8 * b)) return 2;
    return 0;
}
// full decode -> FASTA bytes; 0 ok, 1 decode error, 2 block hash, 3 FASTA XXH3
static int full_v1(const V1& X, const Ref& ref, std::string& fa, bool verify, int T) {
    std::vector<uint8_t> A(X.nbases + 64); std::atomic<uint64_t> next{0}; std::atomic<int> err{0};
    std::vector<std::thread> th; for (int t = 0; t < T; t++) th.emplace_back([&] { std::vector<RrOp> ops(RR_MAXOPS); std::vector<uint8_t> lit(X.Q);
        for (;;) { const uint64_t b = next.fetch_add(1); if (b >= X.nb || err) break; const int e = block_v1(X, ref, b, &A[b * X.Q], ops, lit, verify); if (e) { int z = 0; err.compare_exchange_strong(z, e); } } });
    for (auto& x : th) x.join(); if (err) return err;
    for (auto& r : X.low) for (uint64_t x = r.first; x < r.first + r.second; x++) A[x] |= 0x20;
    fa.clear(); fa.reserve(X.nbases + X.nbases / 60 + 1024);
    for (auto& r : X.rec) { fa += '>'; fa += r.hdr; fa += '\n'; for (uint64_t x = 0; x < r.len; x += r.lw) { fa.append((const char*)&A[r.boff + x], std::min<uint64_t>(r.lw, r.len - x)); fa += '\n'; } }
    if (verify && XXH3_64bits(fa.data(), fa.size()) != X.fasta_xxh) return 3;
    return 0;
}

// ---------------------------------------------------------------- commands
static int cmd_encode(char** argv, int argc) {
    const uint32_t Q = (uint32_t)atoi(argv[3]); const int T = atoi(argv[4]); if (!q_ok(Q)) { fprintf(stderr, "Q must be 1024, 2048, 4096 or 16384\n"); return 1; }
    Ref ref = load_ref(argv[2], T, true); const std::vector<uint8_t> f = slurp(argv[5]);
    const double t0 = now_s(); std::vector<uint8_t> o = encode_v1(ref, f, Q, T, !(argc > 7 && !strcmp(argv[7], "nohash"))); const double t = now_s() - t0;
    spit(argv[6], o.data(), o.size()); printf("V1ENC\t%s\tQ %u\t%zu B\t%.1f s\n", argv[6], Q, o.size(), t); return 0;
}
static int cmd_decode(char** argv) {
    Ref ref = load_ref(argv[2], 1, false); const std::vector<uint8_t> a = slurp(argv[3]); V1 X; std::string why;
    if (open_v1(a.data(), a.size(), ref, X, why)) { fprintf(stderr, "refused: %s\n", why.c_str()); return 2; }
    std::string fa; const double t0 = now_s(); const int e = full_v1(X, ref, fa, true, (int)std::thread::hardware_concurrency());
    if (e) { fprintf(stderr, "decode failed (%s)\n", e == 1 ? "block" : e == 2 ? "block XXH3" : "FASTA XXH3"); return 3; }
    spit(argv[4], fa.data(), fa.size()); printf("V1DEC\t%s\t%zu B FASTA\t%.1f s\tall hashes ok\n", argv[3], fa.size(), now_s() - t0); return 0;
}
static int cmd_info(char** argv) {
    const std::vector<uint8_t> a = slurp(argv[2]); if (a.size() < V1_HDR + 2 || memcmp(a.data(), V1_MAGIC, 8)) { printf("not refrel3 v1\n"); return 2; }
    const uint16_t nl = (uint16_t)(a[136] | a[137] << 8);
    printf("refrel3 v%u Q %u flags %u | reference %s sha256 %s, %llu bases | assembly %llu bases, %llu blocks | FASTA XXH3 %016llx | meta %llu B (raw %llu), block hashes %llu B, payload %llu B\n",
           rd32(&a[8]), rd32(&a[12]), rd32(&a[16]), std::string((const char*)&a[138], nl).c_str(), hex(&a[24], 32).c_str(), (unsigned long long)rd64(&a[56]), (unsigned long long)rd64(&a[64]),
           (unsigned long long)rd64(&a[72]), (unsigned long long)rd64(&a[80]), (unsigned long long)rd64(&a[96]), (unsigned long long)rd64(&a[104]), (unsigned long long)rd64(&a[112]), (unsigned long long)rd64(&a[120]));
    return 0;
}
static int cmd_fetch(int argc, char** argv) {
    Ref ref = load_ref(argv[2], 1, false); const std::vector<uint8_t> a = slurp(argv[3]); V1 X; std::string why;
    if (open_v1(a.data(), a.size(), ref, X, why)) { fprintf(stderr, "refused: %s\n", why.c_str()); return 2; }
    std::vector<RrOp> ops(RR_MAXOPS); std::vector<uint8_t> lit(X.Q), blk(X.Q); int rc = 0;
    for (int k = 4; k < argc; k++) { const std::string r = argv[k]; const size_t c = r.rfind(':'), d = r.find('-', c == std::string::npos ? 0 : c);
        const std::string nm = c == std::string::npos ? r : r.substr(0, c); size_t ri = 0; while (ri < X.rec.size() && X.rec[ri].hdr.substr(0, X.rec[ri].hdr.find_first_of(" \t")) != nm) ri++;
        if (ri == X.rec.size()) { fprintf(stderr, "no contig %s\n", nm.c_str()); rc = 1; continue; }
        const Rec& R = X.rec[ri]; uint64_t s1 = 1, e1 = R.len; if (c != std::string::npos) { s1 = strtoull(r.c_str() + c + 1, 0, 10); if (d != std::string::npos) e1 = strtoull(r.c_str() + d + 1, 0, 10); }
        if (s1 < 1 || e1 > R.len || s1 > e1) { fprintf(stderr, "bad range %s\n", r.c_str()); rc = 1; continue; }
        const uint64_t s = R.boff + s1 - 1, e = R.boff + e1; std::string out;
        for (uint64_t b = s / X.Q; b <= (e - 1) / X.Q; b++) { if (block_v1(X, ref, b, blk.data(), ops, lit, true)) { fprintf(stderr, "block %llu failed\n", (unsigned long long)b); return 3; }
            const uint64_t bs = b * X.Q, x0 = std::max(s, bs), x1 = std::min<uint64_t>(e, bs + X.Q); for (uint64_t x = x0; x < x1; x++) out += (char)blk[x - bs]; }
        for (auto& lr : X.low) { const uint64_t x0 = std::max(s, lr.first), x1 = std::min(e, lr.first + lr.second); for (uint64_t x = x0; x < x1; x++) out[x - s] |= 0x20; }
        printf(">%s\n", r.c_str()); for (size_t x = 0; x < out.size(); x += 60) printf("%s\n", out.substr(x, 60).c_str()); }
    return rc;
}
// old refrel3 archives (dir/name.r3 + .meta3.zst) -> q4k + q16k v1, each decoded back == the source by XXH3
static int cmd_recode(char** argv) {
    const int T = atoi(argv[3]); const std::string outdir = argv[5];
    Ref ref = load_ref(argv[2], T, true); FILE* jf = fopen(argv[4], "r"); if (!jf) { perror(argv[4]); return 1; }
    printf("name\turl\thash_type\tsource_hash\tfasta_bytes\tfasta_xxh3\tq4k_bytes\tq4k_sha256\tq16k_bytes\tq16k_sha256\tstatus\tseconds\n"); fflush(stdout);
    char line[8192];
    while (fgets(line, sizeof line, jf)) {
        std::string L(line); while (!L.empty() && (L.back() == '\n' || L.back() == '\r')) L.pop_back(); if (L.empty()) continue;
        std::vector<std::string> f; size_t p0 = 0; for (;;) { const size_t q = L.find('\t', p0); f.push_back(L.substr(p0, q - p0)); if (q == std::string::npos) break; p0 = q + 1; }
        if (f.size() < 5) continue;
        const double t0 = now_s(); std::string fa; std::string st = "ok";
        if (!full3_string(ref.R, f[1], fa)) st = "old-decode-failed";
        uint64_t sx = XXH3_64bits(fa.data(), fa.size()); std::string sz[2] = {"-", "-"}, sh[2] = {"-", "-"};
        if (st == "ok") { const std::vector<uint8_t> src(fa.begin(), fa.end()); std::string().swap(fa);
            const uint32_t Qs[2] = {4096, 16384};
            for (int k = 0; k < 2 && st == "ok"; k++) { std::vector<uint8_t> o = encode_v1(ref, src, Qs[k], T, true);
                const std::string path = outdir + "/" + f[0] + (k ? ".q16k.rr3" : ".q4k.rr3"); spit(path, o.data(), o.size());
                const std::vector<uint8_t> back = slurp(path); V1 X; std::string why, dec;
                if (open_v1(back.data(), back.size(), ref, X, why)) st = "refused:" + why;
                else if (full_v1(X, ref, dec, true, T) || XXH3_64bits(dec.data(), dec.size()) != sx || dec.size() != src.size()) st = k ? "q16k-differs" : "q4k-differs";
                uint8_t d[32]; rr_sha256(back.data(), back.size(), d); sz[k] = std::to_string(back.size()); sh[k] = hex(d, 32); }
            printf("%s\t%s\t%s\t%s\t%zu\t%016llx\t%s\t%s\t%s\t%s\t%s\t%.1f\n", f[0].c_str(), f[2].c_str(), f[3].c_str(), f[4].c_str(), src.size(), (unsigned long long)sx, sz[0].c_str(), sh[0].c_str(), sz[1].c_str(), sh[1].c_str(), st.c_str(), now_s() - t0);
        } else printf("%s\t%s\t%s\t%s\t-\t-\t-\t-\t-\t-\t%s\t%.1f\n", f[0].c_str(), f[2].c_str(), f[3].c_str(), f[4].c_str(), st.c_str(), now_s() - t0);
        fflush(stdout);
    }
    fclose(jf); return 0;
}
// corruption: 6 kinds (as hw-apex-bench), cases per kind, a forked process per case (the reference shared copy-on-write),
// 10 s watchdog; outcome: refused (open), caught (decode / hash), harmless (== original), silent (differs), hang, crash
static int cmd_corrupt(char** argv) {
    Ref ref = load_ref(argv[2], 1, false); const std::vector<uint8_t> clean = slurp(argv[3]); const int per = atoi(argv[4]); const bool verify = atoi(argv[5]) != 0;
    const uint64_t seed = strtoull(argv[6], 0, 10); const int PAR = atoi(argv[7]);
    uint64_t want = 0; { V1 X; std::string why, fa; if (open_v1(clean.data(), clean.size(), ref, X, why) || full_v1(X, ref, fa, true, 1)) { printf("clean archive does not decode\n"); return 2; } want = XXH3_64bits(fa.data(), fa.size()); }
    const char* kinds[6] = {"bit_flip", "random_bytes", "zeroed_run", "truncation", "header", "payload"}; const char* outs[6] = {"refused", "caught", "harmless", "SILENT", "hang", "crash"};
    long cnt[6][6] = {{0}}; const size_t n = clean.size();
    struct Run { pid_t pid; int kind; double t0; bool killed; }; std::vector<Run> run;
    auto reap = [&](bool block) { for (size_t r = 0; r < run.size();) { int stt = 0; const pid_t g = waitpid(run[r].pid, &stt, WNOHANG);
            if (g == 0) { if (now_s() - run[r].t0 > 10.0 && !run[r].killed) { kill(run[r].pid, SIGKILL); run[r].killed = true; } r++; continue; }
            int o; if (run[r].killed) o = 4; else if (WIFSIGNALED(stt)) o = 5; else { const int c = WEXITSTATUS(stt); o = c == 20 ? 0 : c == 30 ? 1 : c == 0 ? 2 : c == 10 ? 3 : 5; }
            cnt[run[r].kind][o]++; run.erase(run.begin() + (long)r); }
        if (block && !run.empty()) { struct timespec ts = {0, 2000000}; nanosleep(&ts, nullptr); } };
    for (int kind = 0; kind < 6; kind++) for (int c = 0; c < per; c++) {
        while ((int)run.size() >= PAR) reap(true);
        std::mt19937_64 g(seed * 1000003 + (uint64_t)kind * 100000007 + (uint64_t)c); std::vector<uint8_t> a = clean;
        auto pos = [&](uint64_t lo, uint64_t hi) { return hi <= lo ? lo : lo + g() % (hi - lo); };
        if (kind == 0) { const uint64_t p = pos(0, n); a[p] ^= (uint8_t)(1u << (g() % 8)); }
        else if (kind == 1) { const uint64_t l = 1 + g() % 16, p = pos(0, n - std::min<uint64_t>(l, n) + 1); for (uint64_t k = 0; k < l && p + k < n; k++) a[p + k] = (uint8_t)g(); }
        else if (kind == 2) { const uint64_t l = 16 + g() % 4081, p = pos(0, n - std::min<uint64_t>(l, n) + 1); for (uint64_t k = 0; k < l && p + k < n; k++) a[p + k] = 0; }
        else if (kind == 3) { a.resize(pos(0, n)); }
        else if (kind == 4) { const uint64_t p = pos(0, std::min<uint64_t>(1024, n)); a[p] ^= (uint8_t)(1u << (g() % 8)); }
        else { const uint64_t p = pos(std::min<uint64_t>(1024, n - 1), n); a[p] ^= (uint8_t)(1u << (g() % 8)); }
        fflush(stdout); const pid_t pid = fork();
        if (pid == 0) { V1 X; std::string why, fa; if (open_v1(a.data(), a.size(), ref, X, why)) _exit(20);
            const int e = full_v1(X, ref, fa, verify, 1); if (e) _exit(30); _exit(XXH3_64bits(fa.data(), fa.size()) == want ? 0 : 10); }
        run.push_back({pid, kind, now_s(), false});
    }
    while (!run.empty()) reap(true);
    printf("CORRUPT\t%s\tverify %d\t%d per kind\n", argv[3], verify ? 1 : 0, per);
    long tot[6] = {0}; for (int k = 0; k < 6; k++) { printf("CKIND\t%s", kinds[k]); for (int o = 0; o < 6; o++) { printf("\t%s %ld", outs[o], cnt[k][o]); tot[o] += cnt[k][o]; } printf("\n"); }
    printf("CTOTAL"); for (int o = 0; o < 6; o++) printf("\t%s %ld", outs[o], tot[o]); printf("\t%s\n", tot[4] == 0 && tot[5] == 0 ? "no hang, no crash" : "HANG OR CRASH");
    return tot[4] || tot[5] ? 5 : 0;
}
int main(int argc, char** argv) {
    for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
    if (argc >= 7 && !strcmp(argv[1], "encode")) return cmd_encode(argv, argc);
    if (argc >= 5 && !strcmp(argv[1], "decode")) return cmd_decode(argv);
    if (argc >= 3 && !strcmp(argv[1], "info")) return cmd_info(argv);
    if (argc >= 5 && !strcmp(argv[1], "fetch")) return cmd_fetch(argc, argv);
    if (argc >= 6 && !strcmp(argv[1], "recode")) return cmd_recode(argv);
    if (argc >= 8 && !strcmp(argv[1], "corrupt")) return cmd_corrupt(argv);
    fprintf(stderr, "usage: refrel3v1 encode|decode|info|fetch|recode|corrupt ... (see the header)\n"); return 1;
}
