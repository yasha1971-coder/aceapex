#include "aceapex.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
int main(int c, char** v) { FILE* f = fopen(v[1], "rb"); fseek(f, 0, 2); size_t n = ftell(f); fseek(f, 0, 0); std::vector<unsigned char> in(n); if (fread(in.data(), 1, n, f) != n) return 2; fclose(f);
  for (int a = 2; a < c; a++) { const int lv = atoi(v[a]); std::vector<unsigned char> z(aceapex_compress_bound(n) + 4096), o(n + 64);
    const long long zs = aceapex_compress(in.data(), n, z.data(), z.size(), lv, 2); long long d = zs > 0 ? aceapex_decompress_mt(z.data(), zs, o.data(), n, 2) : -99;
    const bool ok = d == (long long)n && (n == 0 || !memcmp(o.data(), in.data(), n));
    unsigned long long h = 1469598103934665603ull; for (long long i = 0; i < zs; i++) h = (h ^ z[i]) * 1099511628211ull;
    printf("L%d %lld B fnv %016llx rt %s\n", lv, zs, h, ok ? "ok" : "FAIL"); } }
