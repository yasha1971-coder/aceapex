// dna_exc_test.cpp - claim head_dna_exc_reject, C++ part (2.6.6): a DNA pack (literal chunk mode 1) whose header has
// exceptions (nexc > 0) but no gap or val frame (h3 or h4 = 0) is refused by every C++ entry point - decompress, mt (1 and
// 2 threads), region, ranges, stream; the intact archive decodes. README.md of this directory. Each call in a child process.
//   default build:          dna_exc_h3h4zero.aet refused on all 6 (and dna_exc_intact.aet whole on all 6)   -> pass
//   -DAX_DNA_EXC_NO_CHECK:  the control - the damaged archive returns the full size on every entry point
// Prints: dna_exc_cpp <check|control> <pass|fail> <detail>. Usage: dna_exc_test <this directory>
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
static int call(int ep, const std::vector<uint8_t>& a, uint64_t n) {   // child exit 0 refused, 1 full size, 2 other
    pid_t pid = fork();
    if (pid == 0) {
        std::vector<uint8_t> d(n + 64, 0x5A); int64_t r = -1;
        if (ep == 0) r = aceapex_decompress(a.data(), a.size(), d.data(), n);
        else if (ep == 1) r = aceapex_decompress_mt(a.data(), a.size(), d.data(), n, 1);
        else if (ep == 2) r = aceapex_decompress_mt(a.data(), a.size(), d.data(), n, 2);
        else if (ep == 3) r = aceapex_decompress_region(a.data(), a.size(), d.data(), n, 0, n);
        else if (ep == 4) { aceapex_range_t g = {0, n, d.data(), 0}; const int64_t t = aceapex_decompress_ranges(a.data(), a.size(), &g, 1, 1); r = t < 0 ? t : g.written; }
        else { Mem m{&a, {}}; r = aceapex_decompress_stream(rd, &m, wr, &m, 1, 0); }
        _exit(r < 0 ? 0 : r == (int64_t)n ? 1 : 2);
    }
    int st = 0; waitpid(pid, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 100;
}
int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <dir>\n", argv[0]); return 2; }
#ifdef AX_DNA_EXC_NO_CHECK
    const bool control = true;
#else
    const bool control = false;
#endif
    const std::vector<uint8_t> bad = slurp(std::string(argv[1]) + "/dna_exc_h3h4zero.aet"), good = slurp(std::string(argv[1]) + "/dna_exc_intact.aet");
    if (bad.size() < 20 || good.size() < 20) { printf("dna_exc_cpp\t%s\tfail\tinputs missing\n", control ? "control" : "check"); return 1; }
    uint64_t n; memcpy(&n, bad.data() + 12, 8);
    int br = 0, bw = 0, gw = 0, sig = 0;
    for (int ep = 0; ep < 6; ep++) { const int s = call(ep, bad, n), t = call(ep, good, n);
        if (s == 0) br++; if (s == 1) bw++; if (t == 1) gw++; if (s >= 100 || t >= 100) sig++; }
    const bool pass = sig == 0 && gw == 6 && (control ? bw == 6 : br == 6);
    printf("dna_exc_cpp\t%s\t%s\tdamaged: %d of 6 entry points refused, %d full size; intact: %d of 6 whole; %d signals\n",
           control ? "control" : "check", pass ? "pass" : "fail", br, bw, gw, sig);
    return pass ? 0 : 1;
}
