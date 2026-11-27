// boffs_contig_test.cpp - claim head_boffs_contig_reject, C++ part (2.6.6): the three archives of this directory (gen.py)
// have a block whose slices do not start where the previous block's end; every C++ entry point refuses them - decompress,
// mt (1 and 2 threads), region (whole), ranges (one range, whole), stream - and region and ranges over block 6 alone
// refuse the two archives damaged at block 6 (they check the span and its neighbours). The fixture decodes whole.
//   default build:               3 x 6 whole calls + 2 x 2 block-6 calls refused, fixture whole on 6   -> pass
//   -DAX_BOFFS_CONTIG_NO_CHECK:  the control (2.6.5): decompress, mt 1, mt 2 and stream return the full size with bytes
//                                other than the fixture's on all 3 archives, 12 calls (the silent wrong output this claim
//                                closes; region and ranges of 2.6.5 refused some of them by their window check)
// Each call in a child process. Prints: boffs_contig_cpp <check|control> <pass|fail> <detail>.
// Usage: boffs_contig_test <this directory> <fixtures dir>
#include "aceapex_api.cpp"
#include <sys/wait.h>
#include <unistd.h>
#include <fstream>
#include <iterator>
#include <string>
static std::vector<uint8_t> slurp(const std::string& p) {
    std::ifstream f(p, std::ios::binary); return std::vector<uint8_t>(std::istreambuf_iterator<char>(f), {}); }
struct Mem { const std::vector<uint8_t>* a; std::vector<uint8_t> out; };
static int64_t rd(void* c, uint64_t off, void* buf, size_t len) {
    const auto& a = *((Mem*)c)->a; if (off > a.size()) return -1; size_t k = std::min(len, (size_t)(a.size() - off));
    memcpy(buf, a.data() + off, k); return (int64_t)k; }
static int wr(void* c, const void* buf, size_t len) { auto& o = ((Mem*)c)->out; o.insert(o.end(), (const uint8_t*)buf, (const uint8_t*)buf + len); return 0; }
// child exit: 0 refused, 1 full size with the fixture's bytes, 2 full size with other bytes, 3 another result
static int call(int ep, const std::vector<uint8_t>& a, const std::vector<uint8_t>& want, uint64_t off, uint64_t len) {
    pid_t pid = fork();
    if (pid == 0) {
        std::vector<uint8_t> d(len + 64, 0x5A); int64_t r = -1; const uint8_t* got = d.data(); Mem m{&a, {}};
        if (ep == 0) r = aceapex_decompress(a.data(), a.size(), d.data(), len);
        else if (ep == 1) r = aceapex_decompress_mt(a.data(), a.size(), d.data(), len, 1);
        else if (ep == 2) r = aceapex_decompress_mt(a.data(), a.size(), d.data(), len, 2);
        else if (ep == 3) r = aceapex_decompress_region(a.data(), a.size(), d.data(), len, off, len);
        else if (ep == 4) { aceapex_range_t g = {off, len, d.data(), 0}; const int64_t t = aceapex_decompress_ranges(a.data(), a.size(), &g, 1, 1); r = t < 0 ? t : g.written; }
        else { r = aceapex_decompress_stream(rd, &m, wr, &m, 1, 0); got = m.out.data(); }
        _exit(r < 0 ? 0 : r != (int64_t)len ? 3 : !memcmp(got, want.data() + off, len) ? 1 : 2);
    }
    int st = 0; waitpid(pid, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 100;
}
int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <dir> <fixtures dir>\n", argv[0]); return 2; }
#ifdef AX_BOFFS_CONTIG_NO_CHECK
    const bool control = true;
#else
    const bool control = false;
#endif
    const auto fx = slurp(std::string(argv[2]) + "/text_200K.aet");
    if (fx.size() < 68) { printf("boffs_contig_cpp\t%s\tfail\tfixture missing\n", control ? "control" : "check"); return 1; }
    uint64_t n; uint32_t bs; memcpy(&n, fx.data() + 12, 8); memcpy(&bs, fx.data() + 20, 4);
    std::vector<uint8_t> want(n); if (aceapex_decompress_mt(fx.data(), fx.size(), want.data(), n, 1) != (int64_t)n) { printf("boffs_contig_cpp\tfail\tfixture does not decode\n"); return 1; }
    const char* bad[3] = {"last_lit0", "mid_lit0", "mid_lit_shift"};
    int wr_ = 0, ws = 0, sr = 0, fxw = 0, sig = 0, miss = 0; std::string det;
    for (int ep = 0; ep < 6; ep++) { const int s = call(ep, fx, want, 0, n); if (s == 1) fxw++; if (s >= 100) sig++; }
    for (int i = 0; i < 3; i++) { const auto a = slurp(std::string(argv[1]) + "/" + bad[i] + ".aet"); if (a.size() < 68) { miss++; continue; }
        int r = 0, s2 = 0;
        for (int ep = 0; ep < 6; ep++) { const int s = call(ep, a, want, 0, n); if (s == 0) r++; if (s == 2 && ep != 3 && ep != 4) s2++; if (s >= 100) sig++; }
        wr_ += r; ws += s2; det += (det.empty() ? "" : ", ") + std::string(bad[i]) + " " + std::to_string(r) + "/6 refused, " + std::to_string(s2) + "/4 silent";
        if (i) for (int ep = 3; ep <= 4; ep++) { const int s = call(ep, a, want, 6ull * bs, bs); if (s == 0) sr++; if (s >= 100) sig++; } }
    const bool pass = miss == 0 && sig == 0 && fxw == 6 && (control ? ws == 12 : wr_ == 18 && sr == 4);
    printf("boffs_contig_cpp\t%s\t%s\t%s; block 6 alone (region, ranges): %d of 4 refused; fixture whole on %d of 6; %d signals%s\n",
           control ? "control" : "check", pass ? "pass" : "fail", det.c_str(), sr, fxw, sig, miss ? "; inputs missing" : "");
    return pass ? 0 : 1;
}
