// short_block_test.cpp - claim head_short_block_reject (SEC-DEC-2, 27.11.2026): a block whose tokens end before its size
// (a bad token, or a command stream that runs out) is an error on every C++ entry point. Until this fix the C++ match
// decoder (decompress_streams) stopped silently: the block's tail stayed unwritten, the call returned the full size, and
// the output carried the old bytes of the caller's buffer - or, through region / ranges, uninitialized heap from their
// span buffer. The C99 decoder and the GPU match kernel already refused such a block.
// Inputs: the four archives of this directory - corrupted archives found by scripts/api_fuzz.cpp (seed 20261127,
// AXF_DUMP_DIFF, 27.11): default levels 1-3 on 70 000-byte seeds, mutated by a zero run, byte increments, bit flips.
// Each archive through aceapex_decompress, _mt (1 and 2 threads), _region (whole output), _ranges (one range, 1 thread)
// and _stream (no VERIFY: the stream path itself), every call in a child process into a buffer poisoned with 0x5A.
//   default build:              every call refuses (negative code)                              -> pass
//   -DAX_SHORT_BLOCK_NO_CHECK:  the control - a short block reported whole: some call must succeed (rc = full size)
//                               with bytes that are not all written by the decoder, or the archives do not test the path
// Prints: short_block_cpp <check|control> <pass|fail> <detail>. Usage: short_block_test <this directory>
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

// exit status of the child: 0 refused, 1 returned the full size, 2 another return value; a signal = failure
static int call(int ep, const std::vector<uint8_t>& a, uint64_t n) {
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
    int st = 0; waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 100 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <dir>\n", argv[0]); return 2; }
    const char* names[] = {"sb_l2_zero.aet", "sb_l2_zero_b.aet", "sb_l1_flip.aet", "sb_l3_inc.aet"};
    static const char* ep_name[] = {"decompress", "mt1", "mt2", "region", "ranges", "stream"};
#ifdef AX_SHORT_BLOCK_NO_CHECK
    const bool control = true;
#else
    const bool control = false;
#endif
    int refused = 0, whole = 0, other = 0, sig = 0, calls = 0; std::string detail;
    for (const char* nm : names) {
        const std::vector<uint8_t> a = slurp(std::string(argv[1]) + "/" + nm);
        if (a.size() < 20) { printf("short_block_cpp\t%s\tfail\t%s missing\n", control ? "control" : "check", nm); return 1; }
        uint64_t n; memcpy(&n, a.data() + 12, 8);   // ACEPX2 header: orig_size at byte 12
        if (n > ((uint64_t)64 << 20)) { printf("short_block_cpp\t%s\tfail\t%s claims %llu B\n", control ? "control" : "check", nm, (unsigned long long)n); return 1; }
        std::string row = std::string(nm) + ":";
        for (int ep = 0; ep < 6; ep++) { const int s = call(ep, a, n); calls++;
            if (s == 0) refused++; else if (s == 1) whole++; else if (s == 2) other++; else sig++;
            row += std::string(" ") + ep_name[ep] + "=" + (s == 0 ? "refused" : s == 1 ? "whole" : s == 2 ? "other" : "SIGNAL"); }
        detail += (detail.empty() ? "" : "; ") + row;
    }
    const bool pass = sig == 0 && (control ? whole > 0 : refused == calls);
    printf("short_block_cpp\t%s\t%s\t%d calls: %d refused, %d full size, %d other, %d signals | %s\n", control ? "control" : "check", pass ? "pass" : "fail",
           calls, refused, whole, other, sig, detail.c_str());
    return pass ? 0 : 1;
}
