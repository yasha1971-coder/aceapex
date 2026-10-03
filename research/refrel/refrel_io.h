// refrel_io.h - host side of refrel shared by the CPU tool and the GPU tool: FASTA reading (bases with case, record
// layout), the meta file (records, lower-case runs, per-block token / literal spans).
#pragma once
#include "refrel_format.h"
#include <zstd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>
static std::vector<uint8_t> slurp(const std::string& p) { FILE* f = fopen(p.c_str(), "rb"); if (!f) { perror(p.c_str()); exit(1); }
    fseek(f, 0, SEEK_END); std::vector<uint8_t> v((size_t)ftell(f)); fseek(f, 0, SEEK_SET); if (fread(v.data(), 1, v.size(), f) != v.size()) exit(1); fclose(f); return v; }
static void spit(const std::string& p, const void* d, size_t n) { FILE* f = fopen(p.c_str(), "wb"); if (!f || fwrite(d, 1, n, f) != n) { perror(p.c_str()); exit(1); } fclose(f); }
static std::string base(const std::string& p) { size_t s = p.find_last_of('/'); std::string b = s == std::string::npos ? p : p.substr(s + 1);
    for (const char* e : {".fa.gz", ".fa", ".fasta"}) { size_t l = strlen(e); if (b.size() > l && b.compare(b.size() - l, l, e) == 0) return b.substr(0, b.size() - l); } return b; }

// ---------------------------------------------------------------- FASTA: bases (case kept) + record layout
struct Rec { std::string hdr; uint64_t len, boff, foff; uint32_t lw; };     // boff: in the base stream; foff: first base byte in the file
struct Fasta { std::vector<Rec> rec; std::vector<uint8_t> b; };
static Fasta read_fasta(const std::string& path) {
    std::vector<uint8_t> f = slurp(path); Fasta F; F.b.reserve(f.size());
    size_t i = 0;
    while (i < f.size()) {
        if (f[i] != '>') { fprintf(stderr, "%s: no header at byte %zu\n", path.c_str(), i); exit(2); }
        size_t e = i; while (e < f.size() && f[e] != '\n') e++;
        Rec r; r.hdr.assign((const char*)&f[i + 1], e - i - 1); r.boff = F.b.size(); r.foff = e + 1; r.lw = 0; r.len = 0;
        i = e + 1; bool last = false;
        while (i < f.size() && f[i] != '>') {
            size_t le = i; while (le < f.size() && f[le] != '\n') le++;
            if (le == f.size()) { fprintf(stderr, "%s: no final line end\n", path.c_str()); exit(2); }
            const uint32_t w = (uint32_t)(le - i);
            if (last || w == 0) { fprintf(stderr, "%s: irregular line layout in %s\n", path.c_str(), r.hdr.c_str()); exit(2); }
            if (!r.lw) r.lw = w; else if (w > r.lw) { fprintf(stderr, "%s: irregular line layout in %s\n", path.c_str(), r.hdr.c_str()); exit(2); }
            if (w < r.lw) last = true;
            F.b.insert(F.b.end(), f.begin() + i, f.begin() + le); r.len += w; i = le + 1;
        }
        F.rec.push_back(r);
    }
    return F;
}
static std::vector<uint8_t> upper(const std::vector<uint8_t>& b) { std::vector<uint8_t> u(b.size()); for (size_t i = 0; i < b.size(); i++) { uint8_t c = b[i]; u[i] = (c >= 'a' && c <= 'z') ? c - 32 : c; } return u; }

struct Meta { std::vector<Rec> rec; std::vector<std::pair<uint64_t, uint64_t>> low; std::vector<uint64_t> to, lo; uint64_t n = 0, nb = 0; };
static Meta load_meta(const std::string& path) {
    Meta X; std::vector<uint8_t> z = slurp(path); const unsigned long long mn = ZSTD_getFrameContentSize(z.data(), z.size());
    std::vector<uint8_t> M((size_t)mn); if (ZSTD_decompress(M.data(), M.size(), z.data(), z.size()) != mn) { fprintf(stderr, "meta %s\n", path.c_str()); exit(2); }
    size_t i = 8; auto g64 = [&] { uint64_t v; memcpy(&v, &M[i], 8); i += 8; return v; }; auto g32 = [&] { uint32_t v; memcpy(&v, &M[i], 4); i += 4; return v; };
    auto gl = [&] { uint64_t v = 0; int sh = 0; for (;;) { uint8_t c = M[i++]; v |= (uint64_t)(c & 0x7F) << sh; if (!(c & 0x80)) break; sh += 7; } return v; };
    X.n = g64(); const uint32_t nr = g32(); uint64_t bo = 0;
    for (uint32_t r = 0; r < nr; r++) { Rec q; const uint32_t hl = g32(); q.hdr.assign((const char*)&M[i], hl); i += hl; q.len = g64(); q.lw = g32(); q.boff = bo; bo += q.len; q.foff = 0; X.rec.push_back(q); }
    const uint64_t nl = g64(); uint64_t last = 0; for (uint64_t k = 0; k < nl; k++) { const uint64_t g = gl(), l = gl(); X.low.push_back({last + g, l}); last += g + l; }
    X.nb = g64(); X.to.assign(X.nb + 1, 0); X.lo.assign(X.nb + 1, 0);
    for (uint64_t b = 0; b < X.nb; b++) { uint16_t x, y; memcpy(&x, &M[i], 2); memcpy(&y, &M[i + 2], 2); i += 4; X.to[b + 1] = X.to[b] + x; X.lo[b + 1] = X.lo[b] + y; }
    return X;
}
