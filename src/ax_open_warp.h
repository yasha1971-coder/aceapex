/* ax_open_warp.h - per-lane steps of the GPU decoder of the open DNA pack (ADR-019, spec 3.4):
 * the two LEB128 streams of a mode 2 chunk, decoded by one warp per chunk.
 *
 *   cse  run lengths, alternating upper/lower starting with upper -> dst |= 0x20 on lower runs
 *   gap  exception gaps, position = running sum -> dst[pos] = val[k]
 * Both run after the bases are written (k_open_seq), cse before gap, as in spec 3.3.
 *
 * A round covers 32 bytes of the stream, one per lane. A byte < 0x80 ends a value; the lane
 * holding it assembles the value backwards (at most 5 bytes, at most 32 bits). Ballot +
 * popcount give the value's index j, an inclusive warp scan of the values gives its end
 * (running sum), `carry` holds the sum of the rounds before. The CUDA kernels (k_open_cse,
 * k_open_exc in aceapex_gpu.cu) put the collectives between the steps; the CPU emulator
 * scripts/open_warp_emu.cpp runs the same steps lane by lane and compares with
 * axo_dna_decode. Checks are those of axo_dna_decode; any failure sets the lane's `bad`.
 */
#ifndef AX_OPEN_WARP_H
#define AX_OPEN_WARP_H
#include <stdint.h>
#include "ax_rans_warp.h"   /* AXW_HD */
#include "ax_lit_open.h"    /* AXO_HDR, axo_rd32, the CPU reference */

AXW_HD bool axl_term(uint32_t lane, const uint8_t* b, uint32_t n, uint32_t r) {
    const uint32_t t = 32 * r + lane;
    return t < n && b[t] < 0x80;
}
/* value ending at byte 32r+lane (a terminator) */
AXW_HD uint32_t axl_value(uint32_t lane, const uint8_t* b, uint32_t r, bool term, bool& bad) {
    if (!term) return 0;
    const uint32_t t = 32 * r + lane;
    uint64_t v = b[t]; uint32_t k = 1;
    while (k < 5 && t >= k && b[t - k] >= 0x80) { v = (v << 7) | (b[t - k] & 0x7Fu); k++; }
    if (t >= k && b[t - k] >= 0x80) bad = true;                /* a 6th byte */
    if (v > 0xFFFFFFFFull) { bad = true; return 0; }
    return (uint32_t)v;
}
/* the stream must end with a terminator */
AXW_HD bool axl_tail_bad(const uint8_t* b, uint32_t n) { return n == 0 || b[n - 1] >= 0x80; }

/* cse: run j = [end - v, end); lower when j is odd. Returns true if this lane has a lower run
   to paint (the warp then paints it cooperatively). */
AXW_HD bool axl_cse_check(bool term, uint32_t j, uint32_t v, uint64_t end, uint32_t raw, bool& bad) {
    if (!term) return false;
    if (v == 0 && j > 0) bad = true;
    if (end > raw) { bad = true; return false; }
    return (j & 1u) && v > 0;
}
AXW_HD void axl_paint(uint32_t lane, uint8_t* dst, uint64_t start, uint32_t len) {
    for (uint64_t i = lane; i < len; i += 32) dst[start + i] |= 0x20;
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
