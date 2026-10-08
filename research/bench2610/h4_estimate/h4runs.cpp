// h4runs <breaks.tsv> <dir with .brk> <f> <anchors comma-separated by index in breaks.tsv order> - ESTIMATE refinement for
// H4: with the given anchor set, a non-anchor sample's break is COVERED when its key has frequency >= f and an anchor has
// it. Walks every non-anchor sample's breaks in stream order and counts RUNS of consecutive covered breaks (a run = one
// switch to an anchor in a cohort-dictionary model). Three costs of the covered bytes: 0 (upper bound), one switch
// event (repl B) per covered BREAK (conservative bound of h4agg), one switch per RUN (this file). Block boundaries are
// not in the .brk files (first events of blocks are not breaks), so a run may span a block boundary - a slight
// overestimate of the run length.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <unordered_map>
#include <algorithm>
int main(int argc, char** argv) {
    FILE* t = fopen(argv[1], "r"); char line[4096]; std::vector<std::string> names; std::vector<double> base, contb; std::vector<uint64_t> contn;
    fgets(line, sizeof line, t);
    while (fgets(line, sizeof line, t)) { char nm[1024]; unsigned long long nb, ev, br, pl, fb, hb, cn; double bb, sb, cb;
        if (sscanf(line, "%s %llu %llu %llu %lf %lf %llu %llu %llu %llu %lf", nm, &nb, &ev, &br, &bb, &sb, &pl, &fb, &hb, &cn, &cb) != 11) continue;
        names.push_back(nm); base.push_back((double)(fb - hb)); contn.push_back(cn); contb.push_back(cb); }
    fclose(t); const int N = (int)names.size(); const int fmin = atoi(argv[3]);
    uint64_t A = 0; { std::string s = argv[4]; size_t p = 0; while (p < s.size()) { size_t c = s.find(',', p); A |= 1ull << atoi(s.substr(p, c - p).c_str()); if (c == std::string::npos) break; p = c + 1; } }
    double cb = 0; uint64_t cn = 0; for (int s = 0; s < N; s++) { cb += contb[s]; cn += contn[s]; } const double repl = cn ? cb / cn : 0;
    std::unordered_map<uint64_t, uint64_t> mask; mask.reserve(60000000);
    for (int s = 0; s < N; s++) { FILE* f = fopen((std::string(argv[2]) + "/" + names[s] + ".brk").c_str(), "rb"); uint64_t k; float c;
        while (fread(&k, 8, 1, f) == 1 && fread(&c, 4, 1, f) == 1) mask[k] |= 1ull << s; fclose(f); }
    double sumbase = 0; for (double b : base) sumbase += b;
    double cov_bytes = 0, cov_n = 0, runs = 0; std::vector<uint64_t> runhist(8, 0);   // 1, 2-3, 4-7, 8-15, 16-31, 32-63, 64-127, 128+
    for (int s = 0; s < N; s++) {
        if (A >> s & 1) continue;
        FILE* f = fopen((std::string(argv[2]) + "/" + names[s] + ".brk").c_str(), "rb"); uint64_t k; float c; uint64_t run = 0;
        auto close = [&]() { if (run) { runs++; int b = 0; uint64_t r = run; while (r > 1 && b < 7) { r >>= 1; b++; } runhist[b]++; run = 0; } };
        while (fread(&k, 8, 1, f) == 1 && fread(&c, 4, 1, f) == 1) {
            const uint64_t m = mask[k];
            if (__builtin_popcountll(m) >= fmin && (m & A)) { cov_bytes += c / 8.0; cov_n++; run++; } else close();
        }
        close(); fclose(f);
    }
    std::string an; for (int s = 0; s < N; s++) if (A >> s & 1) { if (!an.empty()) an += ","; an += names[s].substr(0, names[s].find('.', 3)); }
    printf("ESTIMATE f=%d anchors=%s (K=%d) repl_switch=%.3f B\n", fmin, an.c_str(), __builtin_popcountll(A), repl);
    printf("covered breaks %.0f, covered bytes %.0f (%.3f MB per sample over N), runs %.0f, mean run length %.2f breaks\n", cov_n, cov_bytes, cov_bytes / N / 1e6, runs, runs ? cov_n / runs : 0);
    const char* hb[8] = {"1", "2-3", "4-7", "8-15", "16-31", "32-63", "64-127", "128+"};
    printf("run length histogram (runs):"); for (int b = 0; b < 8; b++) printf(" %s:%llu", hb[b], (unsigned long long)runhist[b]); printf("\n");
    printf("MB per sample: base %.4f | covered cost 0: %.4f | one switch per break: %.4f | one switch per run: %.4f\n",
           sumbase / N / 1e6, (sumbase - cov_bytes) / N / 1e6, (sumbase - cov_bytes + cov_n * repl) / N / 1e6, (sumbase - cov_bytes + runs * repl) / N / 1e6);
}
