/* dnasplit.c - REGION-TAIL-1 step 2, base measurement: the time of one DNA literal chunk (FORMAT_ACEPX2 §3.3, mode 1)
 * split into its parts, with the code of dna_unpack (c/aceapex_decode.c:172-217, aceapex 2.6.5) copied phase by
 * phase: 4 buffer mallocs, zstd of seq / cse / gap / val, bases (T4 table), case (M8 table), exceptions.
 * Reads a version-2 archive (literal stream at 68 + nb * 64, chunked + tagged layout), takes up to MAXC DNA chunks
 * spread evenly over the stream, decodes each R times and keeps per-phase medians; prints the median over chunks of
 * each phase and the unpack share = (bases + case + exceptions) / total. Every chunk is checked against a reference
 * decode of the same code path (the full chunk once) - a mismatch is an error.
 * Usage: dnasplit ARCHIVE [R=15] [MAXC=400] */
#define _POSIX_C_SOURCE 199309L   /* clock_gettime under -std=c99 */
#include <zstd.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
static uint32_t rd32(const uint8_t* p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t rd64(const uint8_t* p) { uint64_t v; memcpy(&v, p, 8); return v; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec; }
static int cmpd(const void* a, const void* b) { double x = *(const double*)a, y = *(const double*)b; return (x > y) - (x < y); }
static double med(double* v, int n) { qsort(v, (size_t)n, sizeof(double), cmpd); return v[n / 2]; }
static int zdec(ZSTD_DCtx* x, void* d, size_t dn, const void* s, size_t sn) {
    size_t r = ZSTD_decompressDCtx(x, d, dn, s, sn); return !ZSTD_isError(r) && r == dn; }
enum { P_ALLOC, P_ZSEQ, P_ZCSE, P_ZGAP, P_ZVAL, P_BASES, P_CASE, P_EXC, NP };
static const char* PN[NP] = {"malloc", "zstd seq", "zstd cse", "zstd gap", "zstd val", "bases", "case", "exceptions"};
static uint32_t T4[256]; static uint64_t M8[256];
/* dna_unpack of 2.6.5, timed per phase into t[] (ns) */
static int dna_unpack_t(ZSTD_DCtx* x, const uint8_t* s, size_t n, uint8_t* dst, size_t raw, double* t) {
    double c0, c1; int ok = 1;
    if (n < 20) return 0;
    uint32_t nexc = rd32(s), h1 = rd32(s + 4), h2 = rd32(s + 8), h3 = rd32(s + 12), h4 = rd32(s + 16);
    if (20 + (uint64_t)h1 + h2 + h3 + h4 > n || nexc > raw) return 0;
    size_t np = (raw + 3) / 4, nq = (raw + 7) / 8; const uint8_t* p = s + 20;
    c0 = now();
    uint8_t* seq = malloc(np + 1); uint8_t* cse = malloc(nq + 1); uint32_t* gap = malloc((size_t)nexc * 4 + 4); uint8_t* val = malloc((size_t)nexc + 1);
    c1 = now(); t[P_ALLOC] = c1 - c0;
    if (!seq || !cse || !gap || !val) return 0;
    c0 = now(); ok = zdec(x, seq, np, p, h1); p += h1; c1 = now(); t[P_ZSEQ] = c1 - c0;
    c0 = now(); ok = ok && zdec(x, cse, nq, p, h2); p += h2; c1 = now(); t[P_ZCSE] = c1 - c0;
    c0 = now(); if (h3) ok = ok && zdec(x, gap, (size_t)nexc * 4, p, h3); else memset(gap, 0, (size_t)nexc * 4); p += h3; c1 = now(); t[P_ZGAP] = c1 - c0;
    c0 = now(); if (h4) ok = ok && zdec(x, val, nexc, p, h4); else memset(val, 0, nexc); c1 = now(); t[P_ZVAL] = c1 - c0;
    if (ok) {
        c0 = now();
        { size_t full = raw >> 2, k = 0; uint32_t* d32 = (uint32_t*)dst;
          for (; k + 4 <= full; k += 4) { const uint32_t a = T4[seq[k]], b = T4[seq[k + 1]], c = T4[seq[k + 2]], e = T4[seq[k + 3]]; d32[k] = a; d32[k + 1] = b; d32[k + 2] = c; d32[k + 3] = e; }
          for (; k < full; k++) d32[k] = T4[seq[k]];
          for (size_t i = full << 2; i < raw; i++) dst[i] = (uint8_t)"ACGT"[(seq[i >> 2] >> (6 - 2 * (i & 3))) & 3]; }
        c1 = now(); t[P_BASES] = c1 - c0; c0 = now();
        { size_t fullq = raw >> 3, k = 0; uint64_t* d64 = (uint64_t*)dst;
          for (; k + 4 <= fullq; k += 4) { uint32_t m4; memcpy(&m4, cse + k, 4); if (!m4) continue;
            for (int j = 0; j < 4; j++) { const uint8_t m = cse[k + j]; if (m) d64[k + j] |= M8[m]; } }
          for (; k < fullq; k++) { uint8_t m = cse[k]; if (m) d64[k] |= M8[m]; }
          if (fullq < nq) { uint8_t m = cse[fullq]; size_t b = fullq << 3; for (size_t j = 0; b + j < raw; j++) if (m & (0x80 >> j)) dst[b + j] |= 0x20; } }
        c1 = now(); t[P_CASE] = c1 - c0; c0 = now();
        { uint64_t pos = 0; for (uint32_t k = 0; k < nexc; k++) { pos += gap[k]; if (pos < raw) dst[pos] = val[k]; } }
        c1 = now(); t[P_EXC] = c1 - c0;
    }
    free(seq); free(cse); free(gap); free(val);
    return ok;
}
int main(int argc, char** argv) {
    FILE* f; long n; uint8_t* a; int R = argc > 2 ? atoi(argv[2]) : 15, MAXC = argc > 3 ? atoi(argv[3]) : 400;
    for (int v = 0; v < 256; v++) { uint8_t q[4] = {(uint8_t)"ACGT"[(v >> 6) & 3], (uint8_t)"ACGT"[(v >> 4) & 3], (uint8_t)"ACGT"[(v >> 2) & 3], (uint8_t)"ACGT"[v & 3]}; memcpy(&T4[v], q, 4);
        uint8_t w[8]; for (int j = 0; j < 8; j++) w[j] = (v & (0x80 >> j)) ? 0x20 : 0; memcpy(&M8[v], w, 8); }
    if (argc < 2 || !(f = fopen(argv[1], "rb"))) return 2;
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET); a = malloc((size_t)n);
    if (fread(a, 1, (size_t)n, f) != (size_t)n) return 2;
    fclose(f);
    if (memcmp(a, "ACEPX2\0\0", 8) || rd32(a + 8) != 2) { fprintf(stderr, "not a version-2 archive\n"); return 3; }
    const uint32_t nb = rd32(a + 24); const uint8_t* L = a + 68 + (size_t)nb * 64;
    const uint64_t h = rd64(L), S = h & ((1ull << 60) - 1), CH = rd64(L + 8);
    if (!((h >> 62) & 1) || !((h >> 61) & 1) || !((h >> 60) & 1)) { fprintf(stderr, "literal stream not chunked + tagged\n"); return 3; }
    const size_t NW = (size_t)((S + CH - 1) / CH); const uint8_t* tab = L + 16; const uint8_t* data = tab + 8 * NW;
    size_t* off = malloc(sizeof(size_t) * (NW + 1)); off[0] = 0; for (size_t i = 0; i < NW; i++) off[i + 1] = off[i] + (size_t)rd64(tab + 8 * i);
    size_t ndna = 0; for (size_t i = 0; i < NW; i++) if (rd64(tab + 8 * i) && data[off[i]] == 1) ndna++;
    printf("archive %s: %u blocks, literal stream %llu B in %zu chunks of %llu, DNA-pack chunks %zu\n", argv[1], nb, (unsigned long long)S, NW, (unsigned long long)CH, ndna);
    ZSTD_DCtx* x = ZSTD_createDCtx(); uint8_t* dst = malloc(CH + 64); uint8_t* ref = malloc(CH + 64);
    double* per[NP]; for (int k = 0; k < NP; k++) per[k] = malloc(sizeof(double) * (size_t)MAXC);
    double* tot = malloc(sizeof(double) * (size_t)MAXC); double* rv = malloc(sizeof(double) * (size_t)R * NP);
    int m = 0; const size_t step = ndna > (size_t)MAXC ? ndna / (size_t)MAXC : 1; size_t seen = 0;
    for (size_t i = 0; i < NW && m < MAXC; i++) {
        if (!rd64(tab + 8 * i) || data[off[i]] != 1) continue;
        if (seen++ % step) continue;
        const size_t raw = (size_t)((uint64_t)(i + 1) * CH <= S ? CH : S - (uint64_t)i * CH);
        const uint8_t* body = data + off[i] + 1; const size_t bn = (size_t)rd64(tab + 8 * i) - 1; double t[NP];
        memset(t, 0, sizeof t);
        if (!dna_unpack_t(x, body, bn, ref, raw, t)) { printf("DECODE FAIL chunk %zu\n", i); return 1; }
        for (int r = 0; r < R; r++) { memset(t, 0, sizeof t); if (!dna_unpack_t(x, body, bn, dst, raw, t) || memcmp(dst, ref, raw)) { printf("MISMATCH chunk %zu\n", i); return 1; }
            for (int k = 0; k < NP; k++) rv[k * R + r] = t[k]; }
        double sum = 0; for (int k = 0; k < NP; k++) { per[k][m] = med(rv + k * R, R); sum += per[k][m]; } tot[m] = sum; m++;
    }
    double mk[NP], unp = 0, zs = 0, all = 0;
    for (int k = 0; k < NP; k++) { double* c = malloc(sizeof(double) * (size_t)m); memcpy(c, per[k], sizeof(double) * (size_t)m); mk[k] = med(c, m); free(c); }
    for (int k = 0; k < NP; k++) all += mk[k];
    unp = mk[P_BASES] + mk[P_CASE] + mk[P_EXC]; zs = mk[P_ZSEQ] + mk[P_ZCSE] + mk[P_ZGAP] + mk[P_ZVAL];
    printf("chunks timed %d (every %zu-th DNA chunk), %d repeats each, per-phase median over chunks (us):\n", m, step, R);
    for (int k = 0; k < NP; k++) printf("  %-11s %8.2f us  (%5.1f %%)\n", PN[k], mk[k] / 1e3, 100.0 * mk[k] / all);
    printf("  total %.2f us (median of totals %.2f us) | zstd %.1f %% | unpack (bases+case+exceptions) %.1f %% | malloc %.1f %%\n",
           all / 1e3, med(tot, m) / 1e3, 100.0 * zs / all, 100.0 * unp / all, 100.0 * mk[P_ALLOC] / all);
    printf("UNPACK_SHARE %.1f\n", 100.0 * unp / all);
    return 0;
}
