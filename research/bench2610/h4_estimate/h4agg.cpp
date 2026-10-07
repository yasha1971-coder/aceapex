// h4agg <breaks.tsv> <dir with .brk> - ESTIMATE for H4 (cohort anchors), not a format. Reads the per-sample break files
// of h4breaks (key = T2T position x strand where the previous copy ended, cost in bits). A key's frequency = number of
// samples that have it (a sample counted once per key; its cost for the key = sum over its occurrences). Model: K anchor
// samples are kept as ordinary samples (their full size counts); a break of a non-anchor sample is "covered" if its key
// has frequency >= f and at least one anchor has the same key; a covered break costs `repl` instead of its bits
// (repl = 0: upper bound of the saving; repl = mean bits of an exact-continuation copy event of the same archives:
// one copy event per covered break, a conservative bound). Anchors chosen greedily by the size reduction they give.
// Output: frequency histogram of break bytes; table K x f x repl -> MB per sample (no block hashes), N = samples.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <unordered_map>
#include <algorithm>
#include <cmath>
struct KS { uint64_t mask = 0; float cost[1]; };
int main(int argc, char** argv) {
    FILE* t = fopen(argv[1], "r"); char line[4096]; std::vector<std::string> names; std::vector<double> base, contb; std::vector<uint64_t> contn;
    fgets(line, sizeof line, t);
    while (fgets(line, sizeof line, t)) { char nm[1024]; unsigned long long nb, ev, br, pl, fb, hb, cn; double bb, sb, cb;
        if (sscanf(line, "%s %llu %llu %llu %lf %lf %llu %llu %llu %llu %lf", nm, &nb, &ev, &br, &bb, &sb, &pl, &fb, &hb, &cn, &cb) != 11) continue;
        names.push_back(nm); base.push_back((double)(fb - hb)); contn.push_back(cn); contb.push_back(cb); }
    fclose(t); const int N = (int)names.size(); if (N > 64) return 1;
    double cb = 0; uint64_t cn = 0; for (int s = 0; s < N; s++) { cb += contb[s]; cn += contn[s]; }
    const double repl_cont = cn ? cb / cn : 0;                           // bytes
    // key -> index; per key mask and per-sample cost (bytes)
    std::unordered_map<uint64_t, uint32_t> idx; idx.reserve(60000000);
    std::vector<uint64_t> mask; std::vector<std::vector<std::pair<uint8_t, float>>> per;   // sparse per-sample costs
    double total_break = 0;
    for (int s = 0; s < N; s++) {
        FILE* f = fopen((std::string(argv[2]) + "/" + names[s] + ".brk").c_str(), "rb"); uint64_t k; float c;
        while (fread(&k, 8, 1, f) == 1 && fread(&c, 4, 1, f) == 1) {
            auto it = idx.find(k); uint32_t i;
            if (it == idx.end()) { i = (uint32_t)mask.size(); idx.emplace(k, i); mask.push_back(0); per.emplace_back(); } else i = it->second;
            const double cbytes = c / 8.0; total_break += cbytes;
            if (!(mask[i] >> s & 1)) { mask[i] |= 1ull << s; per[i].push_back({(uint8_t)s, (float)cbytes}); } else per[i].back().second += (float)cbytes;
        }
        fclose(f);
    }
    idx.clear(); idx.rehash(0);
    double sumbase = 0; for (double b : base) sumbase += b;
    printf("ESTIMATE (not a format) - N %d samples, keys %zu, break bytes %.0f (%.2f MB per sample), base without block hashes %.4f MB per sample, repl_cont %.3f B per covered break\n",
           N, mask.size(), total_break, total_break / N / 1e6, sumbase / N / 1e6, repl_cont);
    // histogram by frequency
    std::vector<double> hb(N + 1, 0); std::vector<uint64_t> hk(N + 1, 0);
    for (size_t i = 0; i < mask.size(); i++) { const int fr = __builtin_popcountll(mask[i]); hk[fr]++; for (auto& x : per[i]) hb[fr] += x.second; }
    printf("FREQ\tfrequency\tkeys\tbreak_bytes\tMB_per_sample\n");
    for (int fr = 1; fr <= N; fr++) if (hk[fr]) printf("FREQ\t%d\t%llu\t%.0f\t%.4f\n", fr, (unsigned long long)hk[fr], hb[fr], hb[fr] / N / 1e6);
    const int FS[4] = {2, 5, 10, 25}; const int KS_[5] = {0, 1, 2, 4, 8};
    printf("TABLE\tf\trepl\tK\tanchors\tsaved_MB_total\tMB_per_sample\n");
    for (int fi = 0; fi < 4; fi++) for (int ri = 0; ri < 2; ri++) {
        const int fmin = FS[fi]; const double repl = ri ? repl_cont : 0;
        std::vector<uint32_t> el; for (size_t i = 0; i < mask.size(); i++) if (__builtin_popcountll(mask[i]) >= fmin) el.push_back((uint32_t)i);
        uint64_t A = 0; std::vector<int> chosen;
        auto saved_of = [&](uint64_t anchors) { double sv = 0; for (uint32_t i : el) { if (!(mask[i] & anchors)) continue; for (auto& x : per[i]) if (!(anchors >> x.first & 1)) sv += std::max(0.0, (double)x.second - repl); } return sv; };
        int kdone = 0;
        for (int ki = 0; ki < 5; ki++) {
            while (kdone < KS_[ki]) {                       // greedy: the anchor with the largest drop of the total size
                std::vector<double> gain(N, 0);
                for (uint32_t i : el) { const bool cov = mask[i] & A;
                    if (!cov) { double tot = 0; for (auto& y : per[i]) tot += std::max(0.0, (double)y.second - repl);   // all holders are non-anchors here
                        for (auto& x : per[i]) gain[x.first] += tot - std::max(0.0, (double)x.second - repl); }
                    else for (auto& x : per[i]) if (!(A >> x.first & 1)) gain[x.first] -= std::max(0.0, (double)x.second - repl); }
                int best = -1; for (int s = 0; s < N; s++) if (!(A >> s & 1) && (best < 0 || gain[s] > gain[best])) best = s;
                A |= 1ull << best; chosen.push_back(best); kdone++;
            }
            const double sv = saved_of(A);
            std::string an; for (int s : chosen) { if (!an.empty()) an += ","; an += names[s].substr(0, names[s].find(".q16k")); }
            printf("TABLE\t%d\t%s\t%d\t%s\t%.3f\t%.4f\n", fmin, ri ? "cont" : "0", KS_[ki], an.empty() ? "-" : an.c_str(), sv / 1e6, (sumbase - sv) / N / 1e6);
            fflush(stdout);
        }
    }
}
