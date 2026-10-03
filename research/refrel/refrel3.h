// refrel3.h - research: an assembly block as edits against the decoded reference, entropy-coded with static
// per-assembly context models (rANS, one stream per 16 KiB block; the tables in the meta). v1 (refrel_format.h) and
// v2 (refrel_v2.h) stay as they are.
//
// A block is: [literal run, copy]* literal run. Per copy event, in order:
//   LL   literal count, bucketed (context: previous kind class)
//   literals: A C G T N or escape + 8 raw bits; context = the reference base the current diagonal predicts at that
//        position for short runs (<= 8; a SNP is "not this base"), order-2 on the run's own previous literals otherwise
//   (if the block is not full) KIND: CONT (current diagonal, delta 0) / DELTA (current diagonal, small delta) /
//        REP (one of the 3 diagonals before it, small delta) / ABS (strand + 32-bit position) / SELF (in-block copy)
//        context: literal-count class x previous kind class
//   its parameters (bucket + raw bits), then the length - 12 (bucket + raw bits; context: kind)
// Diagonal of a reference copy at block offset o, length L, lowest reference position p: forward c = p - o (next
// expected p = c + o'); reverse complement c = p + L - 1 + o (expected p = c - o' - L' + 1). A cache of 4 diagonals,
// most recent first: copies move theirs to the front; a block starts with the stored diagonal (carried from the previous
// block in the meta) as its only entry.
#pragma once
#include "refrel_format.h"

// ---------------------------------------------------------------- contexts and buckets
enum { R3_LL = 0, R3_LITR = 4, R3_LIT2 = 14, R3_KIND = 31, R3_DELTA = 47, R3_REPK = 49, R3_REPD = 50, R3_DIR = 51, R3_SELF = 52, R3_LEN = 53, R3_NCTX = 58 };
enum { K_CONT = 0, K_DELTA = 1, K_REP = 2, K_ABS = 3, K_SELF = 4 };
#define R3_AB 96                                       // bucket alphabet: 16 small values + 4 per octave
static const int R3_ALPHA[R3_NCTX] = {
    R3_AB, R3_AB, R3_AB, R3_AB,                                  // LL x prevk
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6,                    // LITR (ref base 0..4 x first)
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, // LIT2 (16 order-2 + run start)
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,  // KIND (llc x prevk)
    R3_AB, R3_AB,                                    // DELTA (ll == 0, else)
    3,                                               // REPK
    R3_AB,                                           // REP delta
    2,                                               // DIR
    R3_AB,                                           // SELF distance
    R3_AB, R3_AB, R3_AB, R3_AB, R3_AB };             // LEN x kind
#define R3_PB 12u
#define R3_M (1u << R3_PB)

RR_HD static inline uint32_t r3_bucket(uint64_t v, uint32_t* nb, uint64_t* extra) {
    if (v < 16) { *nb = 0; *extra = 0; return (uint32_t)v; }
    uint32_t e = 63 - __builtin_clzll(v);                                 // >= 4; the two bits under the top one are in the symbol
    *nb = e - 2; *extra = v & ((1ull << (e - 2)) - 1);
    return 16 + (e - 4) * 4 + (uint32_t)((v >> (e - 2)) & 3);
}
RR_HD static inline uint64_t r3_unbucket(uint32_t s, uint64_t extra) {
    if (s < 16) return s;
    const uint32_t e = (s - 16) / 4 + 4, m = (s - 16) & 3;
    return (1ull << e) | ((uint64_t)m << (e - 2)) | extra;
}
RR_HD static inline uint32_t r3_nbits(uint32_t s) { return s < 16 ? 0 : (s - 16) / 4 + 2; }
RR_HD static inline int r3_llc(uint64_t ll) { return ll == 0 ? 0 : ll == 1 ? 1 : ll <= 8 ? 2 : 3; }
RR_HD static inline int r3_kclass(int k) { return k < 0 ? 0 : k == K_CONT ? 1 : (k == K_DELTA || k == K_REP) ? 2 : 3; }
RR_HD static inline int r3_b2(uint8_t c) { switch (c) { case 'A': return 0; case 'C': return 1; case 'G': return 2; case 'T': return 3; case 'N': return 4; default: return 5; } }

// ---------------------------------------------------------------- static tables (decoder side)
struct R3Tab { uint16_t freq[R3_NCTX][R3_AB]; uint16_t cum[R3_NCTX][R3_AB + 1]; uint8_t sym[R3_NCTX][R3_M]; };

// ---------------------------------------------------------------- rANS (byte-wise, state in [2^16, 2^24): 3 bytes flushed per block)
#define R3_L (1u << 16)
struct R3Dec { const uint8_t* p; const uint8_t* e; uint32_t x; int bad; };
RR_HD static inline void r3_dinit(R3Dec* d, const uint8_t* p, uint32_t n) {
    d->p = p; d->e = p + n; d->bad = 0; d->x = 0;
    if (n < 3) { d->bad = 1; return; }
    d->x = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16); d->p += 3;
}
RR_HD static inline uint32_t r3_dsym(R3Dec* d, const R3Tab* T, int c) {
    const uint32_t slot = d->x & (R3_M - 1); const uint32_t s = T->sym[c][slot];
    const uint32_t f = T->freq[c][s]; if (!f) { d->bad = 1; return 0; }
    d->x = f * (d->x >> R3_PB) + slot - T->cum[c][s];
    while (d->x < R3_L) { if (d->p >= d->e) { d->bad = 1; return s; } d->x = (d->x << 8) | *d->p++; }
    return s;
}
RR_HD static inline uint64_t r3_draw(R3Dec* d, uint32_t nb) {                // raw bits, <= 16 per step
    uint64_t v = 0; uint32_t sh = 0;
    while (nb) { const uint32_t k = nb > 16 ? 16 : nb; const uint32_t m = (1u << k) - 1;
        const uint32_t b = d->x & m; d->x >>= k;
        while (d->x < R3_L) { if (d->p >= d->e) { d->bad = 1; return v; } d->x = (d->x << 8) | *d->p++; }
        v |= (uint64_t)b << sh; sh += k; nb -= k; }
    return v;
}
RR_HD static inline uint64_t r3_dval(R3Dec* d, const R3Tab* T, int c) { const uint32_t s = r3_dsym(d, T, c); return r3_unbucket(s, r3_draw(d, r3_nbits(s))); }

// ---------------------------------------------------------------- block decode -> ops (+ literal bytes)
struct R3Diag { uint64_t c; uint32_t dir; };                                // c as two's complement (may be "negative")
RR_HD static inline int64_t r3_exp(R3Diag g, uint32_t o, uint64_t L) { return g.dir ? (int64_t)g.c - (int64_t)o - (int64_t)L + 1 : (int64_t)g.c + (int64_t)o; }
RR_HD static inline R3Diag r3_diag(uint32_t dir, uint64_t p, uint32_t o, uint64_t L) { R3Diag g; g.dir = dir; g.c = dir ? (uint64_t)((int64_t)p + (int64_t)L - 1 + (int64_t)o) : (uint64_t)((int64_t)p - (int64_t)o); return g; }
RR_HD static inline void r3_push(R3Diag* cache, int* nc, R3Diag g) {
    int j = 0; while (j < *nc && !(cache[j].c == g.c && cache[j].dir == g.dir)) j++;
    if (j == *nc) { if (*nc < 4) (*nc)++; j = *nc - 1; }
    for (; j > 0; j--) cache[j] = cache[j - 1]; cache[0] = g;
}
// the reference base the current diagonal predicts at block offset o (0..3, 4 = none)
RR_HD static inline int r3_refbase(const uint8_t* ref, uint64_t ref_n, R3Diag g, uint32_t o) {
    const int64_t q = g.dir ? (int64_t)g.c - (int64_t)o : (int64_t)g.c + (int64_t)o;
    if (q < 0 || (uint64_t)q >= ref_n) return 4;
    const uint8_t b = g.dir ? rr_comp(ref[q]) : ref[q]; const int k = r3_b2(b); return k < 4 ? k : 4;
}
RR_HD static inline int r3_decode_block(const uint8_t* src, uint32_t n, const R3Tab* T, const uint8_t* ref, uint64_t ref_n, uint32_t blen,
                                        R3Diag start, RrOp* ops, uint32_t maxops, uint8_t* lit, uint32_t litcap) {
    R3Dec d; r3_dinit(&d, src, n); if (d.bad) return -1;
    R3Diag cache[4]; int nc = 1; cache[0] = start; int prevk = -1; uint32_t o = 0, k = 0, li = 0;
    const uint8_t B[6] = {'A', 'C', 'G', 'T', 'N', 0};
    while (o < blen) {
        const uint64_t ll = r3_dval(&d, T, R3_LL + r3_kclass(prevk));
        if (d.bad || ll > blen - o || ll > litcap - li) return -1;
        if (ll) {
            uint32_t p1 = 16, p2 = 16;
            for (uint32_t j = 0; j < ll; j++) {
                int c;
                if (ll <= 8) c = R3_LITR + r3_refbase(ref, ref_n, cache[0], o + j) * 2 + (j == 0 ? 1 : 0);
                else c = R3_LIT2 + (p1 == 16 ? 16 : (int)(p2 == 16 ? p1 : p2 * 4 + p1) % 16);
                const uint32_t s = r3_dsym(&d, T, c);
                lit[li + j] = s < 5 ? B[s] : (uint8_t)r3_draw(&d, 8);
                p2 = p1; p1 = s < 4 ? s : 0;
            }
            if (k >= maxops) return -1;
            ops[k].kind = 0; ops[k].src = li; ops[k].dst = o; ops[k].len = (uint32_t)ll; k++; li += (uint32_t)ll; o += (uint32_t)ll;
        }
        if (o == blen) break;
        const int kind = (int)r3_dsym(&d, T, R3_KIND + r3_llc(ll) * 4 + r3_kclass(prevk));
        uint64_t p = 0; uint32_t dir = 0; int ki = 0; int64_t dd = 0; uint64_t dist = 0;
        if (kind == K_CONT || kind == K_DELTA) { if (kind == K_DELTA) { const uint64_t z = r3_dval(&d, T, R3_DELTA + (ll == 0 ? 0 : 1)); dd = (int64_t)(z >> 1) ^ -(int64_t)(z & 1); } }
        else if (kind == K_REP) { ki = 1 + (int)r3_dsym(&d, T, R3_REPK); const uint64_t z = r3_dval(&d, T, R3_REPD); dd = (int64_t)(z >> 1) ^ -(int64_t)(z & 1); if (ki >= nc) return -1; }
        else if (kind == K_ABS) { dir = r3_dsym(&d, T, R3_DIR); p = r3_draw(&d, 32); }
        else if (kind == K_SELF) dist = r3_dval(&d, T, R3_SELF);
        else return -1;
        const uint64_t L = r3_dval(&d, T, R3_LEN + kind) + RR_MINL;
        if (d.bad || L > blen - o || k >= maxops) return -1;
        if (kind == K_SELF) { if (dist == 0 || dist > o) return -1; ops[k].kind = 2; ops[k].src = o - dist; }
        else {
            if (kind != K_ABS) { const R3Diag g = cache[kind == K_REP ? ki : 0]; dir = g.dir; const int64_t e = r3_exp(g, o, L) + dd; if (e < 0) return -1; p = (uint64_t)e; }
            if (p > ref_n || L > ref_n - p) return -1;
            ops[k].kind = dir ? 3 : 1; ops[k].src = p; r3_push(cache, &nc, r3_diag(dir, p, o, L));
        }
        ops[k].dst = o; ops[k].len = (uint32_t)L; k++; o += (uint32_t)L; prevk = kind;
    }
    if (d.x != R3_L || d.p != d.e) return -1;                             // the encoder starts from L: all used
    return (int)k;
}
