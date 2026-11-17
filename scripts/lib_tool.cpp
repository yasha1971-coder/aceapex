// lib_tool.cpp - the library alone, no CLI (Windows gate, scripts/windows_test.sh; builds wherever the library builds):
//   lib_tool d IN.aet OUT    decode through aceapex_decompress_stream and again through aceapex_decompress_mt (4 threads);
//                            both outputs must be equal; OUT gets the bytes. exit 0 / 1
//   lib_tool rt IN LEVEL T   aceapex_compress (T threads) -> aceapex_decompress_mt (T threads) -> the same bytes. exit 0 / 1
#include "aceapex.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
typedef std::vector<unsigned char> Buf;
static bool slurp(const char* p, Buf& v) { FILE* f = fopen(p, "rb"); if (!f) return false; unsigned char b[1 << 16]; size_t n;
    while ((n = fread(b, 1, sizeof b, f)) > 0) v.insert(v.end(), b, b + n); const bool ok = !ferror(f); fclose(f); return ok; }
static int64_t rd(void* c, uint64_t off, void* dst, size_t n) { const Buf& z = *(const Buf*)c; if (off >= z.size()) return 0;
    const size_t k = (size_t)(z.size() - off < n ? z.size() - off : n); memcpy(dst, z.data() + off, k); return (int64_t)k; }
static int wr(void* c, const void* b, size_t n) { Buf& o = *(Buf*)c; o.insert(o.end(), (const unsigned char*)b, (const unsigned char*)b + n); return 0; }
int main(int argc, char** argv) {
    if (argc == 4 && !strcmp(argv[1], "d")) {
        Buf z, s; if (!slurp(argv[2], z)) return 1;
        const int64_t r = aceapex_decompress_stream(rd, &z, wr, &s, 4, ACEAPEX_STREAM_VERIFY);
        if (r < 0 || (uint64_t)r != s.size()) { fprintf(stderr, "stream rc %lld\n", (long long)r); return 1; }
        Buf m(s.size() + 1); const int64_t q = aceapex_decompress_mt(z.data(), z.size(), m.data(), s.size(), 4);
        if (q != r || memcmp(m.data(), s.data(), s.size())) { fprintf(stderr, "mt rc %lld differs from stream\n", (long long)q); return 1; }
        FILE* f = fopen(argv[3], "wb"); if (!f) return 1; const bool ok = fwrite(s.data(), 1, s.size(), f) == s.size(); return fclose(f) == 0 && ok ? 0 : 1;
    }
    if (argc == 5 && !strcmp(argv[1], "rt")) {
        Buf in; if (!slurp(argv[2], in)) return 1; const int L = atoi(argv[3]), T = atoi(argv[4]);
        Buf z(aceapex_compress_bound(in.size())), o(in.size() + 1);
        const int64_t zs = aceapex_compress(in.data(), in.size(), z.data(), z.size(), L, T); if (zs <= 0) return 1;
        const int64_t d = aceapex_decompress_mt(z.data(), (size_t)zs, o.data(), in.size(), T);
        return d == (int64_t)in.size() && !memcmp(o.data(), in.data(), in.size()) ? 0 : 1;
    }
    fprintf(stderr, "usage: lib_tool d IN.aet OUT | lib_tool rt IN LEVEL THREADS\n"); return 2;
}
