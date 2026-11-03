// REL261 item 6: aceapex_decompress_stream on a fast archive whose header claims 2^32-1 blocks / a huge payload:
// must return ACEAPEX_ERR_DATA without allocating the table (before 2.6.1: ~32 GiB vector, bad_alloc through the C API)
#include "aceapex.h"
#include <cstdio>
#include <cstring>
#include <vector>
#include <cstdint>
struct Src { const std::vector<uint8_t>* z; };
static int64_t rd(void* c, uint64_t off, void* dst, size_t n) { const auto& z = *((Src*)c)->z; if (off >= z.size()) return 0; size_t k = std::min<size_t>(n, z.size() - off); memcpy(dst, z.data() + off, k); return (int64_t)k; }
static int wr(void*, const void*, size_t) { return 0; }
int main() {
    std::vector<uint8_t> in(200000); for (size_t i = 0; i < in.size(); i++) in[i] = (uint8_t)(i * 7 % 251);
    std::vector<uint8_t> z(aceapex_compress_bound(in.size())); int64_t zs = aceapex_compress(in.data(), in.size(), z.data(), z.size(), 11, 1); z.resize(zs);
    Src s{&z}; int64_t ok = aceapex_decompress_stream(rd, &s, wr, nullptr, 2, ACEAPEX_STREAM_VERIFY);
    int fails = 0; printf("intact: %lld (want %zu)\n", (long long)ok, in.size()); fails += ok != (int64_t)in.size();
    struct Case { const char* what; int off; uint64_t v; int w; } cs[] = {{"num_blocks 2^32-1", 24, 0xffffffffull, 4}, {"orig 2^40, nb 2^20", 12, 1ull << 40, 8}, {"payload 2^61", 44, 1ull << 61, 8}};
    for (auto& c : cs) { std::vector<uint8_t> b = z; uint64_t v = c.v; memcpy(&b[c.off], &v, c.w);
        if (c.off == 12) { uint32_t nb = 1u << 20; memcpy(&b[24], &nb, 4); }
        Src t{&b}; const int64_t r = aceapex_decompress_stream(rd, &t, wr, nullptr, 2, 0); printf("%s: %lld\n", c.what, (long long)r); fails += r != ACEAPEX_ERR_DATA; }
    printf("%s\n", fails ? "FAIL" : "ok"); return fails;
}
