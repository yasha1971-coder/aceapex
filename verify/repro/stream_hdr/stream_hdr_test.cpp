// stream_hdr_test.cpp - claim head_stream_hdr_reject, C++ part (2.6.6): the four archives of this directory (gen.py) are
// refused by every C++ entry point - decompress, mt (1 and 2 threads), region, ranges, stream - as they were before 2.6.6
// (ax_fse_check, ax_lit_chunks, lit_table_check); the C99 decoder is brought to the same verdict (stream_hdr_c99.c). This
// part has no control of its own: the C++ decoder is not changed by it; it fails if the two decoders part again.
// The fixtures (dna_4096B, text_legacy4) decode whole on all 6. Each call in a child process.
// Prints: stream_hdr_cpp check <pass|fail> <detail>. Usage: stream_hdr_test <this directory> <fixtures dir>
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
    if (argc < 3) { fprintf(stderr, "usage: %s <dir> <fixtures dir>\n", argv[0]); return 2; }
    const char* bad[4] = {"tok_bit63", "litch_e63", "lit4_e63", "lit_tag_nochunk"}; const char* fx[2] = {"dna_4096B", "text_legacy4"};
    int br = 0, gw = 0, sig = 0, miss = 0; std::string det;
    for (const char* b : bad) { const auto a = slurp(std::string(argv[1]) + "/" + b + ".aet"); if (a.size() < 20) { miss++; continue; }
        uint64_t n; memcpy(&n, a.data() + 12, 8); int r = 0;
        for (int ep = 0; ep < 6; ep++) { const int s = call(ep, a, n); if (s == 0) r++; if (s >= 100) sig++; }
        br += r; det += (det.empty() ? "" : ", ") + std::string(b) + " " + std::to_string(r) + "/6 refused"; }
    for (const char* f : fx) { const auto a = slurp(std::string(argv[2]) + "/" + f + ".aet"); if (a.size() < 20) { miss++; continue; }
        uint64_t n; memcpy(&n, a.data() + 12, 8); for (int ep = 0; ep < 6; ep++) { const int s = call(ep, a, n); if (s == 1) gw++; if (s >= 100) sig++; } }
    const bool pass = miss == 0 && sig == 0 && br == 24 && gw == 12;
    printf("stream_hdr_cpp\tcheck\t%s\t%s; fixtures whole on %d of 12; %d signals%s\n", pass ? "pass" : "fail", det.c_str(), gw, sig, miss ? "; inputs missing" : "");
    return pass ? 0 : 1;
}
