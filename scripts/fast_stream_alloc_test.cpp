// fast_stream_alloc_test.cpp - claim head_fast_stream_alloc (2.6.2): the fast streaming decoder (aceapex_decompress_stream
// on a version-3 archive) does not size its buffers from a corrupt header or block table. Two inputs built here byte for
// byte (also written out with --write DIR: verify/repro/fast_stream_alloc/):
//   nb_max     a valid-looking header with nb = UINT32_MAX (bs 1 MiB, orig (nb - 1) * bs + 1, payload 76 * nb), then 4 KiB
//              of zeros: until 2.6.2 the reader allocated the whole block table, 68 + 8 * 2^32 B = 32 GiB, zero-filled
//   table_huge nb = 2, bs 1 MiB, orig 1.5 MiB, payload 2^59, table {0, 2^59 - 76, 2^59}, then 1 KiB of zeros: until 2.6.2
//              the reader allocated the first group's claimed bytes, 2^59 - 76 B (api_fuzz under ASan, 13.11)
// The global operator new records the largest request and refuses (std::bad_alloc) anything above 1 GiB, so the old code
// fails here without touching that memory. Pass: both inputs give ACEAPEX_ERR_DATA or ACEAPEX_ERR_MEMORY and no request
// above 64 MiB. Prints one judge line: head_fast_stream_alloc <pass|fail> <detail>.
#include "aceapex.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <new>
#include <string>
#include <vector>
static size_t g_max = 0;
static void* take(size_t n) { if (n > g_max) g_max = n; if (n > ((size_t)1 << 30)) throw std::bad_alloc(); void* p = malloc(n ? n : 1); if (!p) throw std::bad_alloc(); return p; }
void* operator new(size_t n) { return take(n); }
void* operator new[](size_t n) { return take(n); }
void* operator new(size_t n, const std::nothrow_t&) noexcept { try { return take(n); } catch (...) { return nullptr; } }
void* operator new[](size_t n, const std::nothrow_t&) noexcept { try { return take(n); } catch (...) { return nullptr; } }
void operator delete(void* p) noexcept { free(p); }
void operator delete[](void* p) noexcept { free(p); }
void operator delete(void* p, size_t) noexcept { free(p); }
void operator delete[](void* p, size_t) noexcept { free(p); }
static void w32(uint8_t* p, uint32_t v) { memcpy(p, &v, 4); }
static void w64(uint8_t* p, uint64_t v) { memcpy(p, &v, 8); }
static std::vector<uint8_t> header(uint64_t orig, uint32_t bs, uint32_t nb, uint64_t payload) {
    std::vector<uint8_t> h(68, 0); memcpy(h.data(), "ACEPX2\0\0", 8); w32(&h[8], 3); w64(&h[12], orig); w32(&h[20], bs); w32(&h[24], nb);
    w32(&h[36], 1); w32(&h[40], 16); w64(&h[44], payload); return h; }   // xxh3 at 28 and the reserved 52..67 stay zero
struct Src { const std::vector<uint8_t>* z; };
static int64_t rd(void* c, uint64_t off, void* dst, size_t n) { const std::vector<uint8_t>& z = *((Src*)c)->z; if (off >= z.size()) return 0;
    const size_t k = (size_t)std::min<uint64_t>(n, z.size() - off); memcpy(dst, z.data() + off, k); return (int64_t)k; }
static int wr(void*, const void*, size_t) { return 0; }
int main(int argc, char** argv) {
    std::vector<std::pair<std::string, std::vector<uint8_t>>> in;
    { const uint32_t nb = UINT32_MAX, bs = 1u << 20; std::vector<uint8_t> a = header((uint64_t)(nb - 1) * bs + 1, bs, nb, 76ull * nb);
      a.resize(a.size() + 4096, 0); in.push_back({"nb_max", a}); }
    { const uint64_t P = 1ull << 59; std::vector<uint8_t> a = header(3u << 19, 1u << 20, 2, P);
      a.resize(68 + 24, 0); w64(&a[68], 0); w64(&a[76], P - 76); w64(&a[84], P); a.resize(a.size() + 1024, 0); in.push_back({"table_huge", a}); }
    if (argc == 3 && !strcmp(argv[1], "--write")) for (auto& [nm, a] : in) { FILE* f = fopen((std::string(argv[2]) + "/" + nm + ".bin").c_str(), "wb"); if (f) { fwrite(a.data(), 1, a.size(), f); fclose(f); } }
    bool ok = true; std::string det;
    for (auto& [nm, a] : in) for (int th : {1, 8}) {
        g_max = 0; Src s{&a}; int64_t r;
        try { r = aceapex_decompress_stream(rd, &s, wr, nullptr, th, 0); } catch (...) { r = 1; }   // an exception out of the C API is a failure
        const bool good = (r == ACEAPEX_ERR_DATA || r == ACEAPEX_ERR_MEMORY) && g_max <= ((size_t)64 << 20);
        ok = ok && good; char b[160]; snprintf(b, sizeof b, " %s t%d: rc %lld, largest request %zu B%s;", nm.c_str(), th, (long long)r, g_max, good ? "" : " FAIL"); det += b;
    }
    printf("head_fast_stream_alloc\t%s\tcorrupt v3 archives through aceapex_decompress_stream, requests above 1 GiB refused, pass = rc -2 or -3 and none above 64 MiB:%s\n", ok ? "pass" : "fail", det.c_str());
    return ok ? 0 : 1;
}
