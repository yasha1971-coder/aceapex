// zstd_legacy_test.cpp - claim head_zstd_legacy_reject, C++ part (2.6.5, SEC-ZSTD-1): no zstd frame other than a v1
// frame reaches libzstd from any C++ entry point. Inputs: the four archives of this directory (gen.py). Each one through
// aceapex_decompress, aceapex_decompress_mt (1 thread), _region (whole output), _ranges (one range), _stream (VERIFY)
// and CLI d, every call in a child process (a signal is a failure).
// Default build (the check): zl_v1 decodes to its .expect on every entry point; zl_v07, zl_v1_v07, zl_skip_v1 fail on
// every one. -DAX_ZFRAME_NO_CHECK (negative control): zl_skip_v1 decodes on every entry point (any libzstd), and when
// the linked libzstd decodes legacy frames (probe: the v0.7 frame alone) zl_v07 and zl_v1_v07 decode to their .expect
// too - so the archives reach the legacy decoder unless the check stops them. Prints one line:
// zstd_legacy_cpp <check|control> <pass|fail> <detail>. Usage: zstd_legacy_test <dir of this directory> <tmp dir>
#define ACEAPEX_CLI
#define main aceapex_cli_main
#include "aceapex_api.cpp"
#undef main
#include <sys/wait.h>
#include <unistd.h>
#include <fstream>
#include <iterator>
#include <string>

static std::vector<uint8_t> slurp(const std::string& p) {
    std::ifstream f(p, std::ios::binary); return std::vector<uint8_t>(std::istreambuf_iterator<char>(f), {});
}
struct Mem { const std::vector<uint8_t>* a; std::vector<uint8_t> out; };
static int64_t rd(void* c, uint64_t off, void* buf, size_t len) {
    const auto& a = *((Mem*)c)->a; if (off > a.size()) return -1; size_t k = std::min(len, (size_t)(a.size() - off));
    memcpy(buf, a.data() + off, k); return (int64_t)k;
}
static int wr(void* c, const void* buf, size_t len) { auto& o = ((Mem*)c)->out; o.insert(o.end(), (const uint8_t*)buf, (const uint8_t*)buf + len); return 0; }

// 1 = decoded to exactly `want`, 0 = refused (negative code / non-zero exit), 2 = signal or wrong bytes on success
static int call(int ep, const std::vector<uint8_t>& a, const std::vector<uint8_t>& want, const std::string& path, const std::string& tmp) {
    pid_t pid = fork();
    if (pid == 0) {
        std::vector<uint8_t> d(want.size() + 64); int64_t r = -1; std::vector<uint8_t> got;
        if (ep == 0) r = aceapex_decompress(a.data(), a.size(), d.data(), want.size());
        else if (ep == 1) r = aceapex_decompress_mt(a.data(), a.size(), d.data(), want.size(), 1);
        else if (ep == 2) r = aceapex_decompress_region(a.data(), a.size(), d.data(), want.size(), 0, want.size());
        else if (ep == 3) { aceapex_range_t g = {0, want.size(), d.data(), 0}; int64_t t = aceapex_decompress_ranges(a.data(), a.size(), &g, 1, 1); r = t < 0 ? t : g.written; }
        else if (ep == 4) { Mem m{&a, {}}; r = aceapex_decompress_stream(rd, &m, wr, &m, 1, ACEAPEX_STREAM_VERIFY); if (r >= 0) { got = m.out; r = (int64_t)got.size(); } }
        else {
            const std::string out = tmp + "/zl_cli.out"; unlink(out.c_str());
            char a0[] = "aceapex", a1[] = "d", a2[] = "--in", a4[] = "--out";
            std::string in = path; char* av[] = {a0, a1, a2, (char*)in.c_str(), a4, (char*)out.c_str(), nullptr};
            int rc = aceapex_cli_main(6, av); if (rc != 0) _exit(0);
            got = slurp(out); r = (int64_t)got.size();
        }
        if (r < 0) _exit(0);
        if (ep < 4) got.assign(d.begin(), d.begin() + (size_t)std::min<int64_t>(r, (int64_t)want.size()));
        _exit(got == want && (size_t)r == want.size() ? 1 : 2);
    }
    int st = 0; waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 2;
}

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: zstd_legacy_test DIR TMP\n"); return 2; }
    const std::string dir = argv[1], tmp = argv[2];
#ifdef AX_ZFRAME_NO_CHECK
    const char* mode = "control";
    // does this libzstd decode the legacy frame at all? (the v0.7 chunk of zl_v07: after the 68-byte header, the
    // 64-byte block entry and the 24-byte literal stream head)
    const std::vector<uint8_t> v07a = slurp(dir + "/zl_v07.aet"); std::vector<uint8_t> probe(1024);
    const size_t pr = ZSTD_decompress(probe.data(), probe.size(), v07a.data() + 68 + 64 + 24, 178);
    const bool legacy = !ZSTD_isError(pr) && pr == 239;
#else
    const char* mode = "check"; const bool legacy = false;
#endif
    const char* names[] = {"zl_v1", "zl_v07", "zl_v1_v07", "zl_skip_v1"};
    const char* eps[] = {"decompress", "mt", "region", "ranges", "stream", "cli"};
    int bad = 0, n = 0; std::string det;
    for (const char* nm : names) {
        const std::string p = dir + "/" + nm + ".aet"; const auto a = slurp(p), want = slurp(dir + "/" + nm + ".expect");
        const bool is_v1 = !strcmp(nm, "zl_v1"), is_skip = !strcmp(nm, "zl_skip_v1");
#ifdef AX_ZFRAME_NO_CHECK
        const int expect = (is_v1 || is_skip || legacy) ? 1 : -1;     // -1: libzstd refuses legacy itself, not judged
#else
        const int expect = is_v1 ? 1 : 0;
#endif
        int ok = 0;
        for (int ep = 0; ep < 6; ep++) {
            const int r = call(ep, a, want, p, tmp);
            if (expect >= 0) { n++; if (r == expect) ok++; else { bad++; det += std::string(" ") + nm + "/" + eps[ep] + "=" + std::to_string(r); } }
        }
        det += std::string(" ") + nm + ":" + (expect < 0 ? "n/a" : std::to_string(ok) + "/6");
    }
    printf("zstd_legacy_cpp\t%s\t%s\t%d/%d calls as expected%s%s\n", mode, bad ? "fail" : "pass", n - bad, n,
           det.c_str(), !strcmp(mode, "control") ? (legacy ? " (libzstd decodes legacy frames)" : " (libzstd without legacy: v0.7 cases not judged)") : "");
    return bad ? 1 : 0;
}
