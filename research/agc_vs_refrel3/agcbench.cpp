// agcbench.cpp - AGC 3.2.4 in process (C API of src/lib-cxx/agc-api.h, libagc.a of the v3.2.4 source build), one agc
// handle per thread opened with prefetching = 1 before timing.
//   agcbench req <archive.agc> <requests.tsv> <truth.tsv> <threads> <warmups> <runs> <label>
//        every request: agc_get_ctg_seq(sample, contig, start, start + len - 1) (0-based inclusive range)
//   agcbench sample <archive.agc> <sample,sample,...> <truth.tsv> <threads> <warmups> <runs> <label>
//        whole samples one after another; each: every contig (order and lengths of the truth = FASTA order) in full,
//        contigs spread over the threads, into one base array per sample
//   agcbench each <archive.agc> <sample,...> <truth.tsv> <threads> 0 1 <label>
//        as sample, but one sample in memory at a time: time = sum of the per-sample decode times, SHA-256 checked and
//        the array freed after each sample (outside timing); one EACH line per sample (all-50 pass)
// After every run (outside timing) SHA-256 of every answer (upper case) == truth; RUN lines (bench_common.h).
#include "bench_common.h"
#include "agc-api.h"
int main(int argc, char** argv) {
    if (argc < 9) { fprintf(stderr, "usage: see header\n"); return 1; }
    const std::string mode = argv[1]; const char* arc = argv[2]; Truth tr = read_truth(argv[4]); const int T = atoi(argv[5]), WU = atoi(argv[6]), R = atoi(argv[7]); const char* label = argv[8];
    const double t0 = now_s_(); std::vector<agc_t*> h(T); for (int t = 0; t < T; t++) { h[t] = agc_open((char*)arc, 1); if (!h[t]) { fprintf(stderr, "agc_open failed\n"); return 2; } }
    printf("OPEN\t%s\t%d handles (prefetching=1)\t%.3f s\n", label, T, now_s_() - t0); fflush(stdout);
    int bad = 0;
    if (mode == "req") {
        std::vector<Req> q = read_reqs(argv[3]); std::vector<std::string> out(q.size()); uint64_t bytes = 0; for (auto& r : q) { bytes += r.len; }
        for (size_t i = 0; i < q.size(); i++) out[i].assign(q[i].len + 1, 0);
        std::atomic<int> err{0};
        bad = protocol(label, WU, R, q.size(), bytes, [&] { par_for(q.size(), T, [&](int t, size_t i) { const int k = agc_get_ctg_seq(h[t], q[i].sample.c_str(), q[i].ctg.c_str(), (int)q[i].start, (int)(q[i].start + q[i].len - 1), &out[i][0]); if (k < 0) err++; }); },
            [&] { size_t ok = 0; for (size_t i = 0; i < q.size(); i++) ok += !err && sha_upper(out[i].data(), q[i].len) == tr.req[q[i].id]; return ok; });
    } else if (mode == "each") {
        std::vector<std::string> S; { std::string s = argv[3]; size_t p = 0; for (;;) { size_t c = s.find(',', p); S.push_back(s.substr(p, c - p)); if (c == std::string::npos) break; p = c + 1; } }
        double tot = 0; uint64_t nb = 0; size_t ok = 0; std::atomic<int> err{0};
        for (auto& smp : S) { auto& cs = tr.ctgs[smp]; std::vector<uint64_t> off(cs.size() + 1, 0); for (size_t c = 0; c < cs.size(); c++) off[c + 1] = off[c] + cs[c].second;
            std::vector<char> A(off.back() + 1); const double a0 = now_s_();
            par_for(cs.size(), T, [&](int t, size_t c) { if (!cs[c].second) return; std::vector<char> b(cs[c].second + 1);
                const int r = agc_get_ctg_seq(h[t], smp.c_str(), cs[c].first.c_str(), 0, (int)cs[c].second - 1, b.data()); if (r < 0) err++; memcpy(&A[off[c]], b.data(), cs[c].second); });
            const double dt = now_s_() - a0; tot += dt; nb += tr.bases[smp]; const bool good = !err && sha_upper(A.data(), tr.bases[smp]) == tr.sample_sha[smp]; ok += good;
            printf("EACH\t%s\t%s\t%.6f\t%llu bytes\t%s\n", label, smp.c_str(), dt, (unsigned long long)tr.bases[smp], good ? "sha256 ok" : "sha256 DIFFERS"); fflush(stdout); }
        printf("RUN\t%s\t0\ttimed\t%.6f\t%zu items\t%llu bytes\tsha256 %zu/%zu\n", label, tot, S.size(), (unsigned long long)nb, ok, S.size()); bad = ok != S.size();
    } else {
        std::vector<std::string> S; { std::string s = argv[3]; size_t p = 0; for (;;) { size_t c = s.find(',', p); S.push_back(s.substr(p, c - p)); if (c == std::string::npos) break; p = c + 1; } }
        uint64_t bytes = 0; for (auto& s : S) bytes += tr.bases[s];
        std::vector<std::vector<char>> A(S.size()); std::atomic<int> err{0};
        bad = protocol(label, WU, R, S.size(), bytes, [&] {
            for (size_t k = 0; k < S.size(); k++) { auto& cs = tr.ctgs[S[k]]; std::vector<uint64_t> off(cs.size() + 1, 0); for (size_t c = 0; c < cs.size(); c++) off[c + 1] = off[c] + cs[c].second;
                A[k].resize(off.back() + 1);
                par_for(cs.size(), T, [&](int t, size_t c) { if (!cs[c].second) return; std::vector<char> b(cs[c].second + 1);
                    const int r = agc_get_ctg_seq(h[t], S[k].c_str(), cs[c].first.c_str(), 0, (int)cs[c].second - 1, b.data()); if (r < 0) err++; memcpy(&A[k][off[c]], b.data(), cs[c].second); }); } },
            [&] { size_t ok = 0; for (size_t k = 0; k < S.size(); k++) ok += !err && sha_upper(A[k].data(), tr.bases[S[k]]) == tr.sample_sha[S[k]]; return ok; });
    }
    for (auto x : h) agc_close(x);
    return bad ? 4 : 0;
}
