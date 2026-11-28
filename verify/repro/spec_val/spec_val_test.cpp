// spec_val_test.cpp - claim head_spec_val, C++ part (2.6.7, SPEC-VAL-1): the archives of this directory (gen.py) are refused by
// every C++ entry point - decompress, mt (1 and 2 threads), region (whole), ranges (one range), stream - each by the reader
// rule made one rule in 2.6.7 (FORMAT_ACEPX2 8): empty_v7 (D1), empty_bs128m (D2), lit_ch32k (D7), lit_ch65636 (D6),
// zstd_multi (D8), varint_cut (D9), dna_noexc_h3 (D18).
//   default build: 7 archives x 6 entry points refused                                                       -> pass
//   control -DAX_EMPTY_HDR_NO_CHECK -DAX_LITCH_NO_CHECK -DAX_ZFRAME_MULTI_NO_CHECK -DAX_VARINT_NO_CHECK -DAX_DNA_NOEXC_NO_CHECK
//          (the readers of 2.6.6): aceapex_decompress returns the full size for all 7, with the original's bytes
// Each call in a child process. Prints: spec_val_cpp <check|control> <pass|fail> <detail>. Usage: spec_val_test <dir> <fixtures/conf>
#include "aceapex_api.cpp"
#include <sys/wait.h>
#include <unistd.h>
#include <fstream>
#include <iterator>
#include <string>
static std::vector<uint8_t> slurp(const std::string& p) { std::ifstream f(p, std::ios::binary); return std::vector<uint8_t>(std::istreambuf_iterator<char>(f), {}); }
struct Mem { const std::vector<uint8_t>* a; std::vector<uint8_t> out; };
static int64_t rd(void* c, uint64_t off, void* buf, size_t len) { const auto& a = *((Mem*)c)->a; if (off > a.size()) return -1; size_t k = std::min(len, (size_t)(a.size() - off)); memcpy(buf, a.data() + off, k); return (int64_t)k; }
static int wr(void* c, const void* buf, size_t len) { auto& o = ((Mem*)c)->out; o.insert(o.end(), (const uint8_t*)buf, (const uint8_t*)buf + len); return 0; }
static int call(int ep, const std::vector<uint8_t>& a, const std::vector<uint8_t>& want) {   // 0 refused, 1 full size + want, 2 other
    pid_t pid = fork();
    if (pid == 0) { const uint64_t n = want.size(); std::vector<uint8_t> d(n + 64, 0x5A); int64_t r = -1; const uint8_t* got = d.data(); Mem m{&a, {}};
        if (ep == 0) r = aceapex_decompress(a.data(), a.size(), d.data(), n);
        else if (ep == 1) r = aceapex_decompress_mt(a.data(), a.size(), d.data(), n, 1);
        else if (ep == 2) r = aceapex_decompress_mt(a.data(), a.size(), d.data(), n, 2);
        else if (ep == 3) r = aceapex_decompress_region(a.data(), a.size(), d.data(), n, 0, n);
        else if (ep == 4) { aceapex_range_t g = {0, n, d.data(), 0}; const int64_t t = aceapex_decompress_ranges(a.data(), a.size(), &g, 1, 1); r = t < 0 ? t : g.written; }
        else { r = aceapex_decompress_stream(rd, &m, wr, &m, 1, 0); got = m.out.data(); }
        _exit(r < 0 ? 0 : (r == (int64_t)n && (n == 0 || !memcmp(got, want.data(), n))) ? 1 : 2); }
    int st = 0; waitpid(pid, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 100;
}
int main(int argc, char** argv) {
#if defined(AX_EMPTY_HDR_NO_CHECK) && defined(AX_LITCH_NO_CHECK) && defined(AX_ZFRAME_MULTI_NO_CHECK) && defined(AX_VARINT_NO_CHECK) && defined(AX_DNA_NOEXC_NO_CHECK)
    const bool control = true;
#else
    const bool control = false;
#endif
    if (argc < 3) return 2;
    const std::string D = argv[1], F = argv[2];
    const char* cs[7][2] = {{"empty_v7", ""}, {"empty_bs128m", ""}, {"lit_ch32k", "text_767B"}, {"lit_ch65636", "text_767B"},
                            {"zstd_multi", "text_767B"}, {"varint_cut", "dna_open_4097B"}, {"dna_noexc_h3", "dna_noexc_intact"}};
    int refused = 0, calls = 0, ctl_ok = 0, sig = 0, miss = 0; std::string det;
    for (auto& c : cs) {
        const auto a = slurp(D + "/" + c[0] + ".aet"); if (a.size() < 68) { miss++; continue; }
        std::vector<uint8_t> want;
        if (*c[1]) { const auto f = slurp(std::string(strcmp(c[1], "dna_noexc_intact") ? F : D) + "/" + c[1] + ".aet"); uint64_t n; memcpy(&n, f.data() + 12, 8); want.resize(n);
            if (aceapex_decompress_mt(f.data(), f.size(), want.data(), n, 1) != (int64_t)n) { miss++; continue; } }
        int r = 0; for (int ep = 0; ep < 6; ep++) { const int s = call(ep, a, want); calls++; if (s == 0) r++; if (s >= 100) sig++; }
        refused += r; if (call(0, a, want) == 1) ctl_ok++;
        det += (det.empty() ? "" : ", ") + std::string(c[0]) + " " + std::to_string(r) + "/6"; }
    const bool pass = miss == 0 && sig == 0 && (control ? ctl_ok == 7 : refused == 42);
    printf("spec_val_cpp\t%s\t%s\trefused: %s; decompress whole with the original bytes %d of 7; %d signals%s\n", control ? "control" : "check", pass ? "pass" : "fail", det.c_str(), ctl_ok, sig, miss ? "; inputs missing" : "");
    return pass ? 0 : 1;
}
