// stream_alloc_test.cpp - claim head_stream_alloc (2.6.2): the streaming decoder of the default profile
// (aceapex_decompress_stream on a version-2 archive) does not size its worker buffers from the header's block_size.
// Inputs built here byte for byte: 200 000 B of seeded word text (the 4-part literal layout, streamed since 2.6.2) and
// 200 000 B of seeded A/C/G/T lines (DNA: the chunked layout, streamed by 2.6.1 too), level 1, one thread (one block of
// 256 KiB), then the block_size field (offset 20) set to 0x80040000 - still consistent (1 * block_size >= orig_size):
//   bs_huge          only that field changed: a valid archive, the stream gives the input back (VERIFY on)
//   bs_huge_corrupt  plus one byte of the archive's last quarter changed: ACEAPEX_ERR_DATA (VERIFY on) or ERR_MEMORY
// Until 2.6.2 every worker allocated block_size + 64 B for its output and as much for its tile, zero-filled (~2 GiB per
// worker; api_fuzz seed 20261113001 under MemoryMax 8G was killed by the OOM killer, 13.11). The global operator new
// records the largest request and refuses anything above 1 GiB; each case runs in a child process (the old code
// fails inside a worker thread: std::terminate). Pass: the results above, no request above 64 MiB, at 1 and 4 threads.
// Prints one judge line: head_stream_alloc <pass|fail> <detail>.
#include "aceapex.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <exception>
#include <new>
#include <random>
#include <string>
#include <vector>
#include <unistd.h>
#include <sys/wait.h>
static size_t g_max = 0; static int g_fd = -1;
static void* take(size_t n) { if (n > g_max) g_max = n; if (n > ((size_t)1 << 30)) throw std::bad_alloc(); void* p = malloc(n ? n : 1); if (!p) throw std::bad_alloc(); return p; }
void* operator new(size_t n) { return take(n); }
void* operator new[](size_t n) { return take(n); }
void* operator new(size_t n, const std::nothrow_t&) noexcept { try { return take(n); } catch (...) { return nullptr; } }
void* operator new[](size_t n, const std::nothrow_t&) noexcept { try { return take(n); } catch (...) { return nullptr; } }
void operator delete(void* p) noexcept { free(p); }
void operator delete[](void* p) noexcept { free(p); }
void operator delete(void* p, size_t) noexcept { free(p); }
void operator delete[](void* p, size_t) noexcept { free(p); }
typedef std::vector<uint8_t> Buf;
struct Src { const Buf* z; };
static int64_t rd(void* c, uint64_t off, void* dst, size_t n) { const Buf& z = *((Src*)c)->z; if (off >= z.size()) return 0;
    const size_t k = (size_t)std::min<uint64_t>(n, z.size() - off); memcpy(dst, z.data() + off, k); return (int64_t)k; }
struct Sink { const Buf* want; size_t pos; bool diff; };
static int wr(void* c, const void* b, size_t n) { Sink* s = (Sink*)c; if (s->pos + n > s->want->size() || memcmp(s->want->data() + s->pos, b, n)) s->diff = true; s->pos += n; return 0; }
static void on_terminate() { char b[96]; const int k = snprintf(b, sizeof b, "T %zu\n", g_max); if (write(g_fd, b, k)) {} _exit(3); }
// child: one decode, "rc largest same" into the pipe
static std::string run(const Buf& z, const Buf& want, int th) {
    int fd[2]; if (pipe(fd)) return "pipe";
    const pid_t p = fork();
    if (p == 0) { close(fd[0]); g_fd = fd[1]; std::set_terminate(on_terminate); g_max = 0;
        Src s{&z}; Sink k{&want, 0, false}; int64_t r;
        try { r = aceapex_decompress_stream(rd, &s, wr, &k, th, ACEAPEX_STREAM_VERIFY); } catch (...) { r = 1; }
        char b[96]; const int n = snprintf(b, sizeof b, "%lld %zu %d\n", (long long)r, g_max, (int)(!k.diff && k.pos == want.size()));
        if (write(fd[1], b, n)) {} _exit(0); }
    close(fd[1]); char b[96] = {0}; ssize_t n = read(fd[0], b, sizeof b - 1); close(fd[0]); int st = 0; waitpid(p, &st, 0);
    return n > 0 ? std::string(b, (size_t)n - (b[n - 1] == '\n')) : "no output (status " + std::to_string(st) + ")"; }
int main() {
    std::mt19937 rng(20261113); static const char* wd[] = {"the", "of", "and", "genome", "block", "archive", "stream", "decoder", "worker", "buffer"};
    bool ok = true; std::string det;
    for (int kind = 0; kind < 2; kind++) {
    std::string s; if (kind == 0) while (s.size() < 200000) { s += wd[rng() % 10]; s += (rng() % 11) ? ' ' : '\n'; }
    else for (size_t i = 0; i < 200000; i++) s += (i % 61 == 60) ? '\n' : "ACGT"[rng() & 3];
    const Buf in(s.begin(), s.begin() + 200000);
    Buf z(aceapex_compress_bound(in.size())); const int64_t zs = aceapex_compress(in.data(), in.size(), z.data(), z.size(), 1, 1);
    if (zs <= 0) { printf("head_stream_alloc\tfail\tcompress rc %lld\n", (long long)zs); return 1; }
    z.resize((size_t)zs); uint32_t nb; memcpy(&nb, &z[24], 4);
    Buf a = z; const uint32_t BS = 0x80040000u; memcpy(&a[20], &BS, 4);
    Buf b = a; b[b.size() * 3 / 4] ^= 0x5a;
    ok = ok && nb == 1; det += std::string(kind ? "; DNA" : " text") + " (num_blocks " + std::to_string(nb) + ", archive " + std::to_string(zs) + " B)";
    for (int th : {1, 4}) {
        const std::string r1 = run(a, in, th), r2 = run(b, in, th);
        long long rc1 = 0, rc2 = 0; size_t m1 = ~(size_t)0, m2 = ~(size_t)0; int same1 = 0, same2 = 0;
        const bool p1 = sscanf(r1.c_str(), "%lld %zu %d", &rc1, &m1, &same1) == 3, p2 = sscanf(r2.c_str(), "%lld %zu %d", &rc2, &m2, &same2) == 3;
        const bool g1 = p1 && rc1 == (long long)in.size() && same1 && m1 <= ((size_t)64 << 20);
        const bool g2 = p2 && (rc2 == ACEAPEX_ERR_DATA || rc2 == ACEAPEX_ERR_MEMORY) && m2 <= ((size_t)64 << 20);
        ok = ok && g1 && g2;
        auto one = [](std::string r) { const size_t q = r.find('\n'); return q == std::string::npos ? r : r.substr(0, q) + " ..."; };
        det += " t" + std::to_string(th) + ": bs_huge [" + one(r1) + "]" + (g1 ? "" : " FAIL") + ", bs_huge_corrupt [" + one(r2) + "]" + (g2 ? "" : " FAIL") + ";";
    } }
    printf("head_stream_alloc\t%s\tblock_size 0x80040000 in one-block level-1 archives (text, DNA) through aceapex_decompress_stream + VERIFY, [rc, largest request B, bytes equal], pass = bs_huge gives the input, bs_huge_corrupt rc -2/-3, none above 64 MiB%s\n", ok ? "pass" : "fail", det.c_str());
    return ok ? 0 : 1;
}
