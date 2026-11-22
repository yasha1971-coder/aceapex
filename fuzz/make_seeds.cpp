// make_seeds.cpp - seed corpus for fuzz_api (see fuzz_api.cpp for the input layout): raw-path seeds are byte 0 = 0
// followed by a valid archive (levels 1, 2, 3, 11, 14, 18 of text, DNA lines, zeros, random; 300 B .. 70 KB);
// VERIFY-path seeds are byte 0 = 0x80 | level index, 25 zero bytes (no edit, no cut), then the original.
// Usage: make_seeds DIR
#include "aceapex.h"
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
static uint64_t rs = 88172645463325252ull;
static uint64_t rnd() { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static std::vector<uint8_t> gen(int kind, size_t n) {
    std::vector<uint8_t> p(n); static const char* w[] = {"the ", "block ", "archive ", "genome ", "of ", "and\n"};
    for (size_t i = 0; i < n; ) {
        if (kind == 0) { const char* s = w[rnd() % 6]; while (*s && i < n) p[i++] = (uint8_t)*s++; }
        else if (kind == 1) { p[i] = (i % 61 == 60) ? '\n' : (uint8_t)"ACGT"[rnd() & 3]; i++; }
        else if (kind == 2) p[i++] = 0;
        else p[i++] = (uint8_t)rnd();
    }
    return p;
}
static void put(const std::string& path, const std::vector<uint8_t>& b) {
    FILE* f = fopen(path.c_str(), "wb"); if (!f) return; fwrite(b.data(), 1, b.size(), f); fclose(f);
}
int main(int argc, char** argv) {
    if (argc < 2) return 1;
    static const int lv[] = {1, 2, 3, 11, 14, 18}, li[] = {0, 1, 2, 3, 6, 10};
    static const size_t sz[] = {300, 70000};
    int k = 0;
    for (int kind = 0; kind < 4; kind++) for (size_t n : sz) for (int j = 0; j < 6; j++) {
        const std::vector<uint8_t> in = gen(kind, n);
        std::vector<uint8_t> z(aceapex_compress_bound(n));
        const int64_t zs = aceapex_compress(in.data(), n, z.data(), z.size(), lv[j], 1);
        if (zs <= 0) return 1;
        std::vector<uint8_t> r(1, 0); r.insert(r.end(), z.begin(), z.begin() + zs);
        put(std::string(argv[1]) + "/raw" + std::to_string(k), r);
        std::vector<uint8_t> v(26, 0); v[0] = (uint8_t)(0x80 | li[j]); v.insert(v.end(), in.begin(), in.end());
        put(std::string(argv[1]) + "/verify" + std::to_string(k), v);
        k++;
    }
    printf("%d raw + %d verify seeds\n", k, k);
    return 0;
}
