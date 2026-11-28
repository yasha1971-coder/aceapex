// hdr_version_test.cpp - claim head_hdr_version_reject (2.6.6, J3 of the 2.6.6 gates): an archive whose header version is
// not 2 (and not 3, the fast profile) is refused by every C++ entry point - decompress, mt (1 thread), region (whole),
// ranges (one range), stream, decode_streams - as the CLI and the C99 decoder refuse it. Until 2.6.5 the C++ library read
// any version other than 3 as version 2: an archive of a later format version would have been decoded silently.
// Inputs: the eight archives of this directory (gen.py: two conformance fixtures with versions 0, 1, 4, 0xCE02) and the two
// fixtures themselves (version 2: must decode).
//   default build:             the 8 refused on all 6 entry points (48 calls), the 2 fixtures decode on all 6   -> pass
//   -DAX_HDR_VERSION_NO_CHECK: the control - the 8 decode to their fixture's bytes, or they do not test the check
// Every call in a child process. Prints: hdr_version_cpp <check|control> <pass|fail> <detail>.
// Usage: hdr_version_test <repro dir> <fixtures dir>
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
// child exit: 0 refused, 1 decoded to exactly `want`, 2 another result; a signal = failure
static int call(int ep, const std::vector<uint8_t>& a, const std::vector<uint8_t>& want) {
    pid_t pid = fork();
    if (pid == 0) {
        const uint64_t n = want.size(); std::vector<uint8_t> d(n + 64, 0x5A); int64_t r = -1; const uint8_t* got = d.data();
        Mem m{&a, {}}; aceapex_streams_t s{};
        if (ep == 0) r = aceapex_decompress(a.data(), a.size(), d.data(), n);
        else if (ep == 1) r = aceapex_decompress_mt(a.data(), a.size(), d.data(), n, 1);
        else if (ep == 2) r = aceapex_decompress_region(a.data(), a.size(), d.data(), n, 0, n);
        else if (ep == 3) { aceapex_range_t g = {0, n, d.data(), 0}; const int64_t t = aceapex_decompress_ranges(a.data(), a.size(), &g, 1, 1); r = t < 0 ? t : g.written; }
        else if (ep == 4) { r = aceapex_decompress_stream(rd, &m, wr, &m, 1, 0); got = m.out.data(); }
        else { const int q = aceapex_decode_streams(a.data(), a.size(), &s); r = q < 0 ? q : (int64_t)n; got = want.data(); if (q >= 0) aceapex_streams_free(&s); }
        _exit(r < 0 ? 0 : (r == (int64_t)n && (n == 0 || !memcmp(got, want.data(), n))) ? 1 : 2);
    }
    int st = 0; waitpid(pid, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 100;
}
int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <repro dir> <fixtures dir>\n", argv[0]); return 2; }
#ifdef AX_HDR_VERSION_NO_CHECK
    const bool control = true;
#else
    const bool control = false;
#endif
    const char* fx[2] = {"dna_4096B", "text_200K"}; const char* vv[4] = {"v0", "v1", "v4", "vce02"};
    int bad_refuse = 0, bad_fixture = 0, sig = 0, calls = 0, refused = 0, decoded = 0;
    for (const char* f : fx) {
        const std::vector<uint8_t> base = slurp(std::string(argv[2]) + "/" + f + ".aet");
        uint64_t n; if (base.size() < 20) { printf("hdr_version_cpp\tfail\t%s missing\n", f); return 1; } memcpy(&n, base.data() + 12, 8);
        std::vector<uint8_t> want(n); if (aceapex_decompress_mt(base.data(), base.size(), want.data(), n, 1) != (int64_t)n) { printf("hdr_version_cpp\tfail\t%s does not decode\n", f); return 1; }
        for (int ep = 0; ep < 6; ep++) { const int s = call(ep, base, want); calls++; if (s != 1) bad_fixture++; if (s >= 100) sig++; }
        for (const char* v : vv) {
            const std::vector<uint8_t> a = slurp(std::string(argv[1]) + "/" + f + "_" + v + ".aet");
            for (int ep = 0; ep < 6; ep++) { const int s = call(ep, a, want); calls++;
                if (s == 0) refused++; else if (s == 1) decoded++; if (s >= 100) sig++;
                if (!control && s != 0) bad_refuse++; } }
    }
    const bool pass = sig == 0 && bad_fixture == 0 && (control ? decoded == 48 : bad_refuse == 0 && refused == 48);
    printf("hdr_version_cpp\t%s\t%s\t%d calls: fixtures (version 2) whole on 12 of 12 needed (failed %d); 8 other versions x 6 entry points: %d refused, %d decoded to the fixture's bytes, %d signals\n",
           control ? "control" : "check", pass ? "pass" : "fail", calls, bad_fixture, refused, decoded, sig);
    return pass ? 0 : 1;
}
