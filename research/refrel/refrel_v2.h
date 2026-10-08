// refrel_v2.h - research variant of the refrel token stream (refrel_format.h is v1 and stays as it is):
//   split: the token fields go to six streams instead of one: 0 heads, 1 literal-count escapes, 2 lengths - 12,
//          3 zig-zag deltas (tag 1), 4 absolute positions (tag 2), 5 self distances (tag 3); each has its own statistics
//          when compressed. Unsplit = all six in one stream in token order (= v1 when there is no initial state).
//   carry: every block starts from a stored state (reference pointer, direction) instead of (0, forward), so the first
//          copy of a block can be a continuation; the state is in the meta (delta from the previous block's state
//          moved by one block), the block still decodes alone.
#pragma once
#include "refrel_format.h"

struct RrCur { const uint8_t* p; uint32_t n, i; };
struct RrSrc { RrCur* c[6]; };                                          // unsplit: all six point at one cursor

RR_HD static inline int rr_leb2(RrCur* c, uint64_t* v) { return rr_leb(c->p, c->n, &c->i, v); }

// one block -> ops; ptr0 / rc0: the stored initial state (0 / 0 without carry)
RR_HD static inline int rr_parse2(RrSrc s, uint32_t lit_n, uint64_t ref_n, uint32_t blen, uint64_t ptr0, uint32_t rc0, RrOp* ops, uint32_t maxops) {
    uint32_t li = 0, o = 0, k = 0, rc = rc0; uint64_t ptr = ptr0, a_end = 0, v = 0;
    while (o < blen) {
        RrCur* H = s.c[0]; if (H->i >= H->n) return -1;
        const uint8_t h = H->p[H->i++]; uint64_t ll = h >> 2;
        if (ll == 63) { if (!rr_leb2(s.c[1], &v)) return -1; ll += v; }
        if (ll > blen - o || ll > lit_n - li) return -1;
        if (ll) { if (k >= maxops) return -1; ops[k].kind = 0; ops[k].src = li; ops[k].dst = o; ops[k].len = (uint32_t)ll; k++; li += (uint32_t)ll; o += (uint32_t)ll; }
        if (o == blen) break;
        const uint32_t tag = h & 3; uint64_t arg = 0;
        if (tag != 0 && !rr_leb2(s.c[2 + tag], &arg)) return -1;
        if (!rr_leb2(s.c[2], &v)) return -1;
        const uint64_t L = v + RR_MINL;
        if (L > blen - o || k >= maxops) return -1;
        uint64_t p = 0;
        if (tag == 3) { if (arg == 0 || arg > o) return -1; p = o - arg; ops[k].kind = 2; }
        else {
            int64_t d = 0;
            if (tag == 2) { rc = (uint32_t)(arg & 1); p = arg >> 1; }
            else { if (tag == 1) d = (int64_t)(arg >> 1) ^ -(int64_t)(arg & 1);
                   const int64_t e = rc ? (int64_t)ptr - (int64_t)((uint64_t)o - a_end) - (int64_t)L : (int64_t)ptr + (int64_t)((uint64_t)o - a_end);
                   if (e + d < 0) return -1; p = (uint64_t)(e + d); }
            if (p > ref_n || L > ref_n - p) return -1;
            ops[k].kind = rc ? 3 : 1; ptr = rc ? p : p + L; a_end = o + L;
        }
        ops[k].src = p; ops[k].dst = o; ops[k].len = (uint32_t)L; k++; o += (uint32_t)L;
    }
    if (li != lit_n) return -1;
    return (int)k;
}
