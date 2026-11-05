// api_fuzz.cpp - corrupted archives through the C API, every profile (default levels 1-3, fast levels 11-18), under
// ASan+UBSan (FREEZE-2 a). Seeds: seeded text, DNA lines, zeros, random, short periods and a mix, 1 B .. 2.3 MiB.
// Mutants: bit flips, byte overwrites, truncation, extension, header field edits, zero runs. For each mutant:
//   1) aceapex_decompress_mt into a heap buffer of exactly the size the header claims (<= 64 MiB): ASan sees any byte
//      written past it; the result is an error, or the claimed size with the original bytes ("ok"), or the claimed
//      size with other bytes ("silent": the plain API has no checksum, as lzbench calls it - counted, not a failure);
//   2) aceapex_decompress_stream with ACEAPEX_STREAM_VERIFY (XXH3 of the output against the header): a success must
//      hand out the original bytes - "verified silent" must be 0 (the gate).
// Prints one judge line per profile and a summary; exit 1 on any verified-silent result or a return value that is
// neither an error nor the claimed size. Mode "control": a buffer one byte short passed with the full capacity - ASan
// must report it. Usage: api_fuzz SECONDS [SEED] | api_fuzz control
#include "aceapex.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <vector>
#include <string>
static uint64_t rs = 88172645463325252ull;
static uint64_t rnd() { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static std::vector<uint8_t> gen(int kind, size_t n) {
    std::vector<uint8_t> p(n); static const char* w[] = {"the ", "block ", "archive ", "genome ", "of ", "and\n"};
    for (size_t i = 0; i < n; ) {
        if (kind == 0) { const char* s = w[rnd() % 6]; while (*s && i < n) p[i++] = (uint8_t)*s++; }
        else if (kind == 1) { p[i] = (i % 61 == 60) ? '\n' : (uint8_t)"ACGT"[rnd() & 3]; i++; }
        else if (kind == 2) p[i++] = 0;
        else if (kind == 3) p[i++] = (uint8_t)rnd();
        else if (kind == 4) { const size_t per = 1 + rnd() % 13; for (size_t k = 0; k < 4000 && i < n; k++, i++) p[i] = (uint8_t)('a' + i % per); }
        else { const size_t q = n / 4; for (; i < n; i++) p[i] = i < q ? (uint8_t)"ACGT"[rnd() & 3] : i < 2 * q ? (uint8_t)w[rnd() % 6][0] : i < 3 * q ? (uint8_t)rnd() : 0; }
    }
    return p;
}
static uint64_t rd64(const uint8_t* p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static void wr64(uint8_t* p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }
struct Src { const std::vector<uint8_t>* z; };
static int64_t rd(void* c, uint64_t off, void* dst, size_t n) { const auto& z = *((Src*)c)->z; if (off >= z.size()) return 0; const size_t k = std::min<size_t>(n, z.size() - off); memcpy(dst, z.data() + off, k); return (int64_t)k; }
struct Sink { const std::vector<uint8_t>* want; size_t pos; bool diff; };
static int wr(void* c, const void* b, size_t n) { Sink* s = (Sink*)c; if (s->pos + n > s->want->size() || memcmp(s->want->data() + s->pos, b, n)) s->diff = true; s->pos += n; return 0; }
struct Stat { long total = 0, err = 0, ok = 0, silent = 0, vok = 0, verr = 0, vsilent = 0, bad = 0; };
int main(int argc, char** argv) {
    static const int levels[] = {1, 2, 3, 11, 12, 13, 14, 15, 16, 17, 18};
    static const size_t sizes[] = {1, 7, 80, 300, 4096, 70000, 300000, 1048577, 2300000};
    if (argc > 1 && !strcmp(argv[1], "control")) {
        std::vector<uint8_t> in = gen(0, 300000), z(aceapex_compress_bound(in.size()));
        const int64_t zs = aceapex_compress(in.data(), in.size(), z.data(), z.size(), 1, 1);
        uint8_t* o = (uint8_t*)malloc(in.size() - 1);
        printf("control: decoding %zu bytes into a %zu-byte buffer passed as %zu\n", in.size(), in.size() - 1, in.size()); fflush(stdout);
        printf("rc %lld (an ASan report must come before this line)\n", (long long)aceapex_decompress_mt(z.data(), (size_t)zs, o, in.size(), 1));
        free(o); return 0;
    }
    const int secs = argc > 1 ? atoi(argv[1]) : 60; if (argc > 2) rs ^= strtoull(argv[2], 0, 10) * 0x9E3779B97F4A7C15ull;
    Stat st[2]; const time_t t0 = time(nullptr); long seeds = 0;
    while (time(nullptr) - t0 < secs) {
        const int lv = levels[rnd() % 11], prof = lv >= 11; const size_t n = sizes[rnd() % 9];
        const std::vector<uint8_t> in = gen((int)(rnd() % 6), n);
        std::vector<uint8_t> z(aceapex_compress_bound(n));
        const int64_t zs = aceapex_compress(in.data(), n, z.data(), z.size(), lv, 1 + (int)(rnd() % 2));
        if (zs <= 0) { printf("compress failed: level %d n %zu rc %lld\n", lv, n, (long long)zs); return 1; }
        z.resize((size_t)zs); seeds++;
        for (int m = 0; m < 60; m++) {
            std::vector<uint8_t> b = z; const int op = (int)(rnd() % 8);
            if (op == 4) b.resize((size_t)(rnd() % (uint64_t)b.size()));
            if (op == 5) for (int k = 1 + (int)(rnd() % 64); k > 0; k--) b.push_back((uint8_t)rnd());
            if (op <= 1 && !b.empty()) for (int k = 1 + (int)(rnd() % 8); k > 0; k--) b[rnd() % b.size()] ^= (uint8_t)(1u << (rnd() % 8));
            if (op == 2 && !b.empty()) for (int k = 1 + (int)(rnd() % 4); k > 0; k--) b[rnd() % b.size()] = (uint8_t)rnd();
            if (op == 3 && b.size() >= 68) { const int f = (int)(rnd() % 4); const size_t at = f == 0 ? 12 : f == 1 ? 36 + 8 * (rnd() % 4) : f == 2 ? 20 : 24;
                if (f <= 1) wr64(&b[at], rd64(&b[at]) + (rnd() % 5) - 2); else b[at + rnd() % 4] ^= (uint8_t)(1u << (rnd() % 8)); }
            if (op == 6 && b.size() > 68) { const size_t a = 68 + rnd() % (b.size() - 68), l = 1 + rnd() % 16; memset(&b[a], 0, std::min(l, b.size() - a)); }
            if (op == 7 && b.size() > 68) { const size_t a = 68 + rnd() % (b.size() - 68); b[a] = (uint8_t)(b[a] + 1); }
            Stat& s = st[prof]; s.total++;
            const uint64_t claimed = b.size() >= 20 ? rd64(&b[12]) : 0;
            if (claimed <= (64u << 20)) {
                uint8_t* o = (uint8_t*)malloc(claimed ? (size_t)claimed : 1);
                const int64_t r = aceapex_decompress_mt(b.data(), b.size(), o, (size_t)claimed, 1 + (int)(rnd() % 2));
                if (r < 0) s.err++;
                else if (r == (int64_t)claimed) { if (claimed == in.size() && (claimed == 0 || !memcmp(o, in.data(), in.size()))) s.ok++; else s.silent++; }
                else s.bad++;
                free(o);
            } else s.err++;
            Src src{&b}; Sink sk{&in, 0, false};
            const int64_t v = aceapex_decompress_stream(rd, &src, wr, &sk, 1, ACEAPEX_STREAM_VERIFY);
            if (v < 0) s.verr++;
            else if (v == (int64_t)in.size() && !sk.diff && sk.pos == in.size()) s.vok++;
            else s.vsilent++;
        }
    }
    const char* nm[2] = {"default levels 1-3", "fast levels 11-18"}; long fail = 0;
    for (int p = 0; p < 2; p++) { const Stat& s = st[p]; fail += s.vsilent + s.bad;
        printf("api_fuzz %s: %ld mutants | decompress_mt: %ld errors, %ld ok, %ld SILENT (success + wrong bytes), %ld bad rc | stream+VERIFY: %ld errors, %ld ok, %ld verified-silent\n",
               nm[p], s.total, s.err, s.ok, s.silent, s.bad, s.verr, s.vok, s.vsilent); }
    printf("api_fuzz: %ld seed archives in %d s; gate (verified-silent 0, bad rc 0): %s\n", seeds, secs, fail ? "FAIL" : "pass");
    return fail ? 1 : 0;
}
