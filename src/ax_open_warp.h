/* ax_open_warp.h - per-thread steps of the GPU decoder of the open DNA pack (ADR-019, spec 3.4):
 * the two LEB128 streams of a mode 2 chunk and the base expansion.
 *
 *   cse    run lengths, alternating upper/lower starting with upper -> run ends ends[j]
 *   bases  16 positions per thread: 2-bit bases, case from the run containing the position
 *          (binary search over ends, then a forward walk); one 16-byte store
 *   gap    exception gaps, position = running sum -> dst[pos] = val[k]; after bases
 *
 * The two LEB128 streams are parsed by one thread block per chunk, AXO_NT bytes per round,
 * one byte per thread: a byte < 0x80 ends a value; the thread holding it assembles the value
 * backwards (at most 5 bytes, at most 32 bits). An exclusive block scan of (1 << 44 | value)
 * gives the value's index j and the running sum before it; `carry` and `jb` hold the sums of
 * the rounds before. (Rounds of a whole block, not a warp: a chunk with tens of thousands of
 * exceptions or case runs would otherwise be one warp's serial chain - that tail was most of
 * the 2.8 + 1.8 ms on the T4.) The CUDA kernels (k_open_cse, k_open_bases, k_open_exc in
 * aceapex_gpu.cu) put the scans and barriers between the steps; the CPU emulator
 * scripts/open_warp_emu.cpp runs the same steps thread by thread with the same round width
 * and compares with axo_dna_decode. Checks are those of axo_dna_decode; any failure sets the
 * thread's `bad`.
 */
#ifndef AX_OPEN_WARP_H
#define AX_OPEN_WARP_H
#include <stdint.h>
#include "ax_rans_warp.h"   /* AXW_HD */
#include "ax_lit_open.h"    /* AXO_HDR, axo_rd32, the CPU reference */

#define AXO_NT 256u            /* bytes per parse round = threads per block */
#define AXO_KEY_J (1ull << 44)  /* scan key: count in bits 44.., value sum below (256 x 2^32 < 2^44) */

AXW_HD bool axl_term(uint32_t t, const uint8_t* b, uint32_t n) { return t < n && b[t] < 0x80; }
/* value ending at byte t (a terminator) */
AXW_HD uint32_t axl_value(uint32_t t, const uint8_t* b, bool term, bool& bad) {
    if (!term) return 0;
    uint64_t v = b[t]; uint32_t k = 1;
    while (k < 5 && t >= k && b[t - k] >= 0x80) { v = (v << 7) | (b[t - k] & 0x7Fu); k++; }
    if (t >= k && b[t - k] >= 0x80) bad = true;                /* a 6th byte */
    if (v > 0xFFFFFFFFull) { bad = true; return 0; }
    return (uint32_t)v;
}
/* the stream must end with a terminator */
AXW_HD bool axl_tail_bad(const uint8_t* b, uint32_t n) { return n == 0 || b[n - 1] >= 0x80; }

/* cse: run j ends at `end` (running sum); ends has room for ncse >= number of runs */
AXW_HD void axl_cse_end(bool term, uint32_t j, uint32_t v, uint64_t end, uint32_t raw, uint32_t* ends, bool& bad) {
    if (!term) return;
    if (v == 0 && j > 0) bad = true;
    if (end > raw) { bad = true; return; }
    ends[j] = (uint32_t)end;
}
/* first run whose end is > pos */
AXW_HD uint32_t axl_run_of(const uint32_t* ends, uint32_t R, uint32_t pos) {
    uint32_t lo = 0, hi = R;
    while (lo < hi) { uint32_t mid = (lo + hi) >> 1; if (ends[mid] > pos) hi = mid; else lo = mid + 1; }
    return lo;
}
/* positions 16g .. 16g+15: bases, then case of the run (odd run = lower); R = 0 means all upper */
AXW_HD void axl_bases16(uint32_t g, const uint8_t* seq, const uint32_t* ends, uint32_t R, uint32_t raw, uint8_t* dst) {
    const uint32_t i0 = 16 * g;
    if (i0 >= raw) return;
    uint32_t j = axl_run_of(ends, R, i0), w[4] = {0, 0, 0, 0};   /* 16 bytes in 4 words: registers, no local array */
#ifdef __CUDA_ARCH__
#pragma unroll
#endif
    for (uint32_t k = 0; k < 16; k++) {
        const uint32_t i = i0 + k;
        if (i < raw) {
            while (j < R && ends[j] <= i) j++;
            uint32_t c = (0x54474341u >> (8 * ((seq[i >> 2] >> (6 - 2 * (i & 3))) & 3))) & 0xFFu;   /* "ACGT" */
            if (j & 1u) c |= 0x20;
            w[k >> 2] |= c << (8 * (k & 3));
        }
    }
    if (i0 + 16 <= raw) {
#ifdef __CUDA_ARCH__
        *(uint4*)(dst + i0) = make_uint4(w[0], w[1], w[2], w[3]);
#else
        memcpy(dst + i0, w, 16);
#endif
    } else {
#ifdef __CUDA_ARCH__
#pragma unroll
#endif
        for (uint32_t k = 0; k < 16; k++) if (i0 + k < raw) dst[i0 + k] = (uint8_t)(w[k >> 2] >> (8 * (k & 3)));
    }
}
/* gap: exception j at position end (inclusive running sum) */
AXW_HD void axl_exc(bool term, uint32_t j, uint32_t v, uint64_t end, uint32_t nexc, uint32_t raw,
                    const uint8_t* val, uint8_t* dst, bool& bad) {
    if (!term) return;
    if (j >= nexc || (v == 0 && j > 0) || end >= raw) { bad = true; return; }
    dst[end] = val[j];
}

/* Host side: the mode 2 header and piece framing, checked before anything goes to the device
   (the same size checks as axo_dna_decode). Content checks happen on the device. */
struct AxoParts { uint32_t nexc, ncse, ngap, raw; uint32_t off[4], h[4], n[4]; uint8_t mode[4]; };
static inline int axo_parse(const uint8_t* s, size_t sz, uint32_t raw, AxoParts* P) {
    if (sz < AXO_HDR || raw == 0) return -1;
    P->nexc = axo_rd32(s); P->ncse = axo_rd32(s + 4); P->ngap = axo_rd32(s + 8); P->raw = raw;
    uint64_t o = AXO_HDR;
    for (int k = 0; k < 4; k++) { P->h[k] = axo_rd32(s + 12 + 4 * k); P->off[k] = (uint32_t)o; o += P->h[k]; }
    if (o != sz) return -1;
    if (P->nexc == 0 ? (P->ngap || P->h[2] || P->h[3]) : (P->ngap < P->nexc || !P->h[2] || !P->h[3])) return -1;
    if (P->ncse == 0 || P->nexc > raw) return -1;
    P->n[0] = (raw + 3) / 4; P->n[1] = P->ncse; P->n[2] = P->ngap; P->n[3] = P->nexc;
    for (int k = 0; k < 4; k++) {
        if (P->n[k] == 0) { if (P->h[k]) return -1; P->mode[k] = 0; continue; }
        if (P->h[k] < 1) return -1;
        P->mode[k] = s[P->off[k]];
        if (P->mode[k] > 1 || (P->mode[k] == 0 && P->h[k] - 1 != P->n[k])) return -1;
        P->off[k] += 1; P->h[k] -= 1;                          /* payload of the piece */
    }
    return 0;
}
#endif
