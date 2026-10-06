// rr3bench.cpp - refrel3 v1 in process (aceapex research/refrel @ 5b6d5ce: open_v1 / block_v1 of refrel3v1.cpp, built
// from refrel3v1_nomain.cpp = refrel3v1.cpp with line 243 "int main(" -> "static int refrel3v1_main(" by sed). The
// decoded T2T reference and every archive opened (all FORMAT.md section 5 checks) before timing.
//   rr3bench req <ref.fa> <archive dir> <q4k|q16k> <requests.tsv> <truth.tsv> <threads> <warmups> <runs> <label>
//        every request: the blocks it touches decoded (block_v1, block XXH3 not checked), its bases copied out
//   rr3bench sample <ref.fa> <archive dir> <q4k|q16k> <sample,...> <truth.tsv> <threads> <warmups> <runs> <label>
//        whole samples one after another; each: every block decoded, blocks spread over the threads, into one array
//   rr3bench each ... (as sample) - one sample in memory at a time: time = sum of per-sample decode times, SHA-256 checked
//        and the array freed after each sample (outside timing); EACH line per sample (all-50 pass)
// Archives: <dir>/y1_<sample>.<dataset>.rr3, or <dir>/<manifest name>.<dataset>.rr3 by the map in env AVR_NAMES
// (manifest name <tab> AGC set name = request sample). Output upper case (lower-case runs not applied: the truth is upper case).
#include "refrel3v1_nomain.cpp"
#include "bench_common.h"
int main(int argc, char** argv) {
    if (argc < 11) { fprintf(stderr, "usage: see header\n"); return 1; }
    for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
    const std::string mode = argv[1], dir = argv[3], ds = argv[4]; Truth tr = read_truth(argv[6]); const int T = atoi(argv[7]), WU = atoi(argv[8]), R = atoi(argv[9]); const char* label = argv[10];
    const double t0 = now_s_(); Ref ref = load_ref(argv[2], 1, false);
    std::vector<std::string> names; for (auto& kv : tr.bases) names.push_back(kv.first);
    std::map<std::string, size_t> idx; std::vector<std::vector<uint8_t>> bytes(names.size()); std::vector<std::unique_ptr<V1>> X(names.size());
    std::vector<std::map<std::string, uint64_t>> boff(names.size());
    std::map<std::string, std::string> man; if (getenv("AVR_NAMES")) for (auto& v : read_tsv(getenv("AVR_NAMES"))) man[v[1]] = v[0];
    for (size_t i = 0; i < names.size(); i++) { idx[names[i]] = i; bytes[i] = slurp(dir + "/" + (man.count(names[i]) ? man[names[i]] : "y1_" + names[i]) + "." + ds + ".rr3"); X[i].reset(new V1()); std::string why;
        if (open_v1(bytes[i].data(), bytes[i].size(), ref, *X[i], why)) { fprintf(stderr, "%s refused: %s\n", names[i].c_str(), why.c_str()); return 2; }
        for (auto& r : X[i]->rec) boff[i][r.hdr.substr(0, r.hdr.find_first_of(" \t"))] = r.boff; }
    printf("OPEN\t%s\treference + %zu archives (%s)\t%.3f s\n", label, names.size(), ds.c_str(), now_s_() - t0); fflush(stdout);
    struct Scr { std::vector<RrOp> ops; std::vector<uint8_t> lit, blk; }; std::vector<Scr> sc(T); for (auto& s : sc) { s.ops.resize(RR_MAXOPS); s.lit.resize(X[0]->Q); s.blk.resize(X[0]->Q); }
    std::atomic<int> err{0}; int bad = 0;
    if (mode == "req") {
        std::vector<Req> q = read_reqs(argv[5]); std::vector<std::string> out(q.size()); uint64_t nb = 0; for (auto& r : q) nb += r.len;
        std::vector<size_t> qa(q.size()); std::vector<uint64_t> qs(q.size());
        for (size_t i = 0; i < q.size(); i++) { qa[i] = idx.at(q[i].sample); qs[i] = boff[qa[i]].at(q[i].ctg) + q[i].start; out[i].resize(q[i].len); }
        bad = protocol(label, WU, R, q.size(), nb, [&] { par_for(q.size(), T, [&](int t, size_t i) { const V1& V = *X[qa[i]]; Scr& s = sc[t]; const uint64_t a = qs[i], e = a + q[i].len;
                for (uint64_t b = a / V.Q; b <= (e - 1) / V.Q; b++) { if (block_v1(V, ref, b, s.blk.data(), s.ops, s.lit, false)) { err++; return; }
                    const uint64_t bs = b * V.Q, x0 = std::max(a, bs), x1 = std::min<uint64_t>(e, bs + V.Q); memcpy(&out[i][x0 - a], s.blk.data() + (x0 - bs), x1 - x0); } }); },
            [&] { size_t ok = 0; for (size_t i = 0; i < q.size(); i++) ok += !err && sha_upper(out[i].data(), q[i].len) == tr.req[q[i].id]; return ok; });
    } else if (mode == "each") {
        std::vector<std::string> S; { std::string s = argv[5]; size_t p = 0; for (;;) { size_t c = s.find(',', p); S.push_back(s.substr(p, c - p)); if (c == std::string::npos) break; p = c + 1; } }
        double tot = 0; uint64_t nb = 0; size_t ok = 0;
        for (auto& smp : S) { const V1& V = *X[idx.at(smp)]; std::vector<uint8_t> A(V.nbases + 64); const double a0 = now_s_();
            par_for(V.nb, T, [&](int t, size_t b) { if (block_v1(V, ref, b, &A[b * V.Q], sc[t].ops, sc[t].lit, false)) err++; });
            const double dt = now_s_() - a0; tot += dt; nb += tr.bases[smp]; const bool good = !err && sha_upper((const char*)A.data(), tr.bases[smp]) == tr.sample_sha[smp]; ok += good;
            printf("EACH\t%s\t%s\t%.6f\t%llu bytes\t%s\n", label, smp.c_str(), dt, (unsigned long long)tr.bases[smp], good ? "sha256 ok" : "sha256 DIFFERS"); fflush(stdout); }
        printf("RUN\t%s\t0\ttimed\t%.6f\t%zu items\t%llu bytes\tsha256 %zu/%zu\n", label, tot, S.size(), (unsigned long long)nb, ok, S.size()); bad = ok != S.size();
    } else {
        std::vector<std::string> S; { std::string s = argv[5]; size_t p = 0; for (;;) { size_t c = s.find(',', p); S.push_back(s.substr(p, c - p)); if (c == std::string::npos) break; p = c + 1; } }
        uint64_t nb = 0; for (auto& s : S) nb += tr.bases[s]; std::vector<std::vector<uint8_t>> A(S.size());
        bad = protocol(label, WU, R, S.size(), nb, [&] { for (size_t k = 0; k < S.size(); k++) { const V1& V = *X[idx.at(S[k])]; A[k].resize(V.nbases + 64);
                par_for(V.nb, T, [&](int t, size_t b) { if (block_v1(V, ref, b, &A[k][b * V.Q], sc[t].ops, sc[t].lit, false)) err++; }); } },
            [&] { size_t ok = 0; for (size_t k = 0; k < S.size(); k++) ok += !err && sha_upper((const char*)A[k].data(), tr.bases[S[k]]) == tr.sample_sha[S[k]]; return ok; });
    }
    return bad ? 4 : 0;
}
