// refrel_format.h - research format "refrel" (not ACEPX2): an assembly as LZ77 against a decoded reference.
// The assembly's bases (all records concatenated, upper case; case and line layout kept aside) are cut into 16 KiB
// blocks. A block is a token stream + its literal bytes; a match copies either from the reference (an absolute position
// in the reference's upper-case base stream, resident and decoded) or from earlier bytes of the same block. Blocks never
// read another block, so any block decodes alone.
// Token: head byte = tag (bits 0-1) | literal count (bits 2-7; 63 = 63 + LEB128 follows), then the literals are taken
// from the block's literal bytes; if the block is full the block ends; else by tag:
//   0 reference, position = expected            expected = ref_end + (o - a_end): where the last reference copy would
//   1 reference, position = expected + zigzag(LEB128)    continue if the bases since were copied from it as well
//   2 reference, position = LEB128 (absolute)
//   3 self, distance = LEB128 (>= 1, <= bases out so far; overlap allowed)
// then the length - 12 as LEB128. A reference copy is forward or reverse-complement (assemblies hold contigs in either
// orientation): tag 2 carries 2 x position + rc; tags 0 / 1 continue in the direction of the last reference copy.
// Forward: expected start = ptr + (o - a_end), ptr = end of the last copy. Reverse complement: the copy is the reverse
// complement of reference [p, p+L); expected p = ptr - (o - a_end) - L, ptr = start of the last copy. ptr, a_end and the
// direction start at 0 / forward in every block.
// Shared by the CPU tool (refrel.cpp) and the CUDA kernel (refrel_gpu.cu): rr_parse turns a block's tokens into ops.
#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __CUDACC__
#define RR_HD __host__ __device__
#else
#define RR_HD
#endif

#define RR_BS 16384u
#define RR_MINL 12u
#define RR_MAXOPS 4096u

struct RrOp { uint64_t src; uint32_t dst, len; uint32_t kind; };   // kind 0 literal (src = index in the block's literals), 1 reference, 2 self (src = dst - dist), 3 reference reverse complement of [src, src+len)

RR_HD static inline int rr_leb(const uint8_t* b, uint32_t n, uint32_t* i, uint64_t* v) {
    uint64_t x = 0; int sh = 0;
    for (;;) { if (*i >= n || sh > 63) return 0; uint8_t c = b[(*i)++]; x |= (uint64_t)(c & 0x7F) << sh; if (!(c & 0x80)) break; sh += 7; }
    *v = x; return 1;
}

// tokens of one block -> ops; returns the op count, or -1 on any malformed input (bounds checked against blen, the
// literal count and the reference size). Every byte of the block is covered exactly once, in order.
RR_HD static inline int rr_parse(const uint8_t* tok, uint32_t tn, uint32_t lit_n, uint64_t ref_n, uint32_t blen, RrOp* ops, uint32_t maxops) {
    uint32_t ti = 0, li = 0, o = 0, k = 0, rc = 0; uint64_t ptr = 0, a_end = 0, v = 0;
    while (o < blen) {
        if (ti >= tn) return -1;
        const uint8_t h = tok[ti++]; uint64_t ll = h >> 2;
        if (ll == 63) { if (!rr_leb(tok, tn, &ti, &v)) return -1; ll += v; }
        if (ll > blen - o || ll > lit_n - li) return -1;
        if (ll) { if (k >= maxops) return -1; ops[k].kind = 0; ops[k].src = li; ops[k].dst = o; ops[k].len = (uint32_t)ll; k++; li += (uint32_t)ll; o += (uint32_t)ll; }
        if (o == blen) break;
        const uint32_t tag = h & 3; uint64_t arg = 0;
        if (tag != 0 && !rr_leb(tok, tn, &ti, &arg)) return -1;
        if (!rr_leb(tok, tn, &ti, &v)) return -1;
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
    if (ti != tn || li != lit_n) return -1;                          // every token and literal used
    return (int)k;
}

RR_HD static inline uint8_t rr_comp(uint8_t c) { switch (c) { case 'A': return 'T'; case 'C': return 'G'; case 'G': return 'C'; case 'T': return 'A'; default: return c; } }
// sequential execution (CPU, and the reference for the GPU kernel's two-phase version)
RR_HD static inline void rr_exec(const RrOp* ops, int n, const uint8_t* lit, const uint8_t* ref, uint8_t* out) {
    for (int k = 0; k < n; k++) {
        const RrOp& q = ops[k];
        if (q.kind == 0) for (uint32_t j = 0; j < q.len; j++) out[q.dst + j] = lit[q.src + j];
        else if (q.kind == 1) for (uint32_t j = 0; j < q.len; j++) out[q.dst + j] = ref[q.src + j];
        else if (q.kind == 2) for (uint32_t j = 0; j < q.len; j++) out[q.dst + j] = out[q.src + j];
        else for (uint32_t j = 0; j < q.len; j++) out[q.dst + j] = rr_comp(ref[q.src + q.len - 1 - j]);
    }
}
