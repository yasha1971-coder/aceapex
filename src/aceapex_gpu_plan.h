/* aceapex_gpu_plan.h - host side of the GPU library (src/aceapex_gpu.h): an ACEPX2 archive in host memory
 * -> a plan of device jobs, in plain C++ with no CUDA type, so the same code is judged on the CPU
 * (scripts/gpu_plan_emu.cpp executes a plan job by job and compares with the original).
 *
 * Every job refers to the archive by offset (the device copy d_in is only known at decode time) and to
 * its output by offset into the caller's temp buffer d_temp. The device descriptors (RansDesc, OpenDesc,
 * DnaDesc of src/aceapex_gpu_kernels.cuh) are built here with those offsets in their pointer fields; the
 * library copies them into d_temp and adds the base address (the "fixup") in the decode call, so the
 * async calls need neither an allocation nor a host->device copy of host memory.
 *
 * Temp layout (all offsets 256-aligned): four stream buffers, zstd DNA scratch, open scratch, case-run ends,
 * run counts, error words, block counter, nvCOMP arrays and temp, the fixed-up descriptor arrays. A range
 * decode adds a window of whole blocks after that.
 *
 * Range selection: blocks [b0,b1) cover [offset, offset+length); each stream's byte range for those blocks
 * maps to a chunk index range, and every job array is ordered by (stream, chunk), so the jobs needed are
 * a contiguous index range per array and stream (agp_select).
 */
#ifndef ACEAPEX_GPU_PLAN_H
#define ACEAPEX_GPU_PLAN_H
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <vector>
#include <algorithm>
#include "ax_open_warp.h"   /* axo_parse (mode 2 framing), AXO_* */

namespace agp {

/* layouts identical to RansDesc / OpenDesc / DnaDesc in aceapex_gpu_kernels.cuh (pointer fields hold
   offsets into d_temp; UINT64_MAX = null) */
struct Rans { uint64_t src, dst; uint32_t csz, n, mode, pad; };
struct Open { uint64_t seq, cse, gap, val, dst, ends, nrun; uint32_t raw, ncse, ngap, nexc; };
struct Dna  { uint64_t seq, cse, gap, val, dst; uint32_t raw, nexc; };
struct Nv   { uint64_t in_off, csz, out_off, osz; };          /* one zstd frame for nvCOMP */
struct Raw  { uint64_t src, dst, n; };                         /* a stored token chunk: d_in -> d_temp */
struct Seg  { uint32_t lo, hi; };
static const uint64_t NUL = ~0ull;

enum { E_OK = 0, E_HEADER = 1, E_TABLE = 2, E_STREAM = 3, E_LAYOUT = 4, E_NVCOMP = 5 };
enum { C_TOK = 0, C_SEQ = 1, C_CSE = 2, C_GAP = 3, C_VAL = 4, C_PLAIN = 5, C_N = 6 };   /* rANS piece classes */

struct Plan {
    uint64_t orig = 0, in_bytes = 0; uint32_t bs = 0, nb = 0;
    uint64_t ssz[4] = {0, 0, 0, 0}, chunk[4] = {0, 0, 0, 0};
    std::vector<uint8_t> bo;                                   /* nb x 64 B block table, as in the archive */
    std::vector<Nv> nv;  std::vector<uint64_t> nv_key;  size_t NT = 0;   /* [0,NT) token frames, then literal */
    std::vector<Rans> rans; std::vector<uint64_t> rans_key; size_t cls_off[C_N + 1] = {0};
    std::vector<Open> open; std::vector<uint64_t> open_key;
    std::vector<Dna>  dna;  std::vector<uint64_t> dna_key;
    std::vector<Raw>  raw;  std::vector<uint64_t> raw_key;
    bool contiguous = true;                                    /* block slices back to back in every stream (range decode needs it) */
    uint64_t max_osz = 0, nv_out_total = 0, nv_temp = 0;
    /* temp layout */
    uint64_t o_s[4], o_scr, o_os, o_ends, o_nrun, o_err, o_ctr, o_nvcp, o_nvop, o_nvcs, o_nvos, o_nvact, o_nvst, o_nvtmp,
             o_rans, o_open, o_dna, temp_bytes;
};
static inline uint64_t key(uint32_t st, uint64_t chunk) { return ((uint64_t)st << 48) | chunk; }
static inline uint64_t rd64(const uint8_t* p) { uint64_t v; memcpy(&v, p, 8); return v; }
static inline uint32_t rd32(const uint8_t* p) { uint32_t v; memcpy(&v, p, 4); return v; }
static inline uint64_t al(uint64_t x) { return (x + 255) & ~255ull; }

/* nv_temp(n, max_out, total_out): nvCOMP temp bytes for n frames (nullptr: no nvCOMP; frames are refused) */
typedef uint64_t (*NvTempFn)(size_t n, size_t max_out, size_t total_out);

static inline int build(const uint8_t* a, size_t in_bytes, Plan& P, NvTempFn nvt) {
    P = Plan();
    if (!a || in_bytes < 68 || memcmp(a, "ACEPX2\0\0", 8) || rd32(a + 8) != 2) return E_HEADER;
    P.in_bytes = in_bytes; P.orig = rd64(a + 12); P.bs = rd32(a + 20); P.nb = rd32(a + 24);
    const uint64_t zsz[4] = {rd64(a + 36), rd64(a + 44), rd64(a + 52), rd64(a + 60)};
    if (P.nb == 0 || P.bs == 0 || (uint64_t)P.nb * P.bs < P.orig || (uint64_t)(P.nb - 1) * P.bs >= P.orig) return E_HEADER;
    uint64_t p = 68 + 64ull * P.nb, zoff[4];
    if (p > in_bytes) return E_HEADER;
    for (int i = 0; i < 4; i++) { zoff[i] = p; if (zsz[i] > in_bytes - p) return E_HEADER; p += zsz[i]; }
    P.bo.assign(a + 68, a + 68 + 64ull * P.nb);
    /* token streams off/len/cmd */
    for (int st = 1; st < 4; st++) {
        const uint8_t* z = a + zoff[st]; if (zsz[st] < 8) continue;
        uint64_t w = rd64(z), osz = w & ((1ull << 48) - 1), ch = ((w >> 48) & 0x7fff) * 4096;
        if (!ch) { const char* e = getenv("FSE_CHUNK"); ch = e ? strtoull(e, 0, 10) : 524288; }
        if (!ch) return E_STREAM;
        P.ssz[st] = osz; P.chunk[st] = ch; uint64_t nc = (osz + ch - 1) / ch, pos = 8 + 8 * nc;
        if (nc > (zsz[st] - 8) / 8 || pos > zsz[st]) return E_STREAM;
        for (uint64_t i = 0; i < nc; i++) {
            uint64_t cs = rd64(z + 8 + 8 * i), raw = std::min<uint64_t>(ch, osz - i * ch);
            if (((cs >> 48) & 0x3fff) || ((cs >> 63) && ((cs >> 62) & 1))) return E_STREAM;
            uint64_t csz = (cs >> 63) ? raw : (cs & ((1ull << 48) - 1));
            if (csz > zsz[st] - pos) return E_STREAM;
            if (cs >> 63) { P.raw.push_back({zoff[st] + pos, ((uint64_t)st << 56) | (i * ch), raw}); P.raw_key.push_back(key(st, i)); }
            else if ((cs >> 62) & 1) { P.rans.push_back({zoff[st] + pos, ((uint64_t)st << 56) | (i * ch), (uint32_t)csz, (uint32_t)raw, 1, C_TOK}); P.rans_key.push_back(key(st, i)); }
            else { P.nv.push_back({zoff[st] + pos, csz, ((uint64_t)st << 56) | (i * ch), raw}); P.nv_key.push_back(key(st, i)); }
            pos += csz;
        }
    }
    P.NT = P.nv.size();
    /* literal stream: FSE layout bit 62 required (as the GPU tool) */
    std::vector<uint64_t> scr_off;                      /* zstd DNA scratch sub-buffers: (offset, size) */
    uint64_t scr = 0, oscr = 0, nends = 0;
    {
        const uint8_t* z = a + zoff[0];
        if (zsz[0] < 8) { if (P.orig) return E_STREAM; }
        else {
            uint64_t h = rd64(z); bool b62 = h & (1ull << 62), chunked = h & (1ull << 61), tagged = h & (1ull << 60);
            if (!b62 || (h >> 63)) return E_STREAM;
            uint64_t sz = h & ((1ull << 60) - 1);
            uint64_t CH = chunked ? (zsz[0] >= 16 ? rd64(z + 8) : 0) : (sz + 3) / 4;
            if (chunked && !CH) return E_STREAM;
            uint64_t NW = chunked ? (sz + CH - 1) / CH : 4, hd = chunked ? 16 : 8;
            if (NW > (zsz[0] - hd) / 8) return E_STREAM;
            uint64_t pos = hd + 8 * NW; P.ssz[0] = sz; P.chunk[0] = CH ? CH : 1;
            if (pos > zsz[0]) return E_STREAM;
            for (uint64_t t = 0; t < NW; t++) {
                uint64_t o = t * CH, raw = o >= sz ? 0 : (o + CH <= sz ? CH : sz - o), csz = rd64(z + hd + 8 * t);
                const uint64_t cpos = zoff[0] + pos; const uint8_t* c = a + cpos;
                if (csz > zsz[0] - pos) return E_STREAM;
                pos += csz;
                if (!raw) continue;
                if (!csz) return E_STREAM;              /* a chunk with bytes needs a body */
                const uint64_t dst0 = o;                /* literal-stream offset */
                if (tagged && csz && c[0] == 2) {
                    AxoParts Q; if (csz < 2 || axo_parse(c + 1, csz - 1, (uint32_t)raw, &Q)) return E_STREAM;
                    uint64_t off[4];
                    for (int q = 0; q < 4; q++) { off[q] = oscr; oscr += al((uint64_t)Q.n[q] + 64);
                        if (Q.n[q]) { P.rans.push_back({cpos + 1 + Q.off[q], (6ull << 56) | off[q], Q.h[q], Q.n[q], Q.mode[q], (uint32_t)(C_SEQ + q)}); P.rans_key.push_back(key(0, t)); } }
                    Open d; d.seq = off[0]; d.cse = off[1]; d.gap = off[2]; d.val = off[3]; d.dst = dst0; d.ends = nends; d.nrun = P.open.size();
                    d.raw = (uint32_t)raw; d.ncse = Q.ncse; d.ngap = Q.ngap; d.nexc = Q.nexc; nends += Q.ncse;
                    P.open.push_back(d); P.open_key.push_back(t); continue;
                }
                if (tagged && csz && c[0] == 3) {
                    if (csz < 2 || c[1] > 1 || (c[1] == 0 && csz - 2 != raw)) return E_STREAM;
                    P.rans.push_back({cpos + 2, dst0, (uint32_t)(csz - 2), (uint32_t)raw, c[1], C_PLAIN}); P.rans_key.push_back(key(0, t)); continue;
                }
                if (tagged && csz && c[0] == 1) {
                    if (csz < 21) return E_STREAM;
                    uint32_t nexc = rd32(c + 1), h1 = rd32(c + 5), h2 = rd32(c + 9), h3 = rd32(c + 13), h4 = rd32(c + 17);
                    if ((uint64_t)21 + h1 + h2 + h3 + h4 > csz || nexc > raw) return E_STREAM;
                    uint64_t f = cpos + 21; Dna d; d.dst = dst0; d.raw = (uint32_t)raw; d.nexc = nexc; d.gap = NUL; d.val = NUL;
                    uint64_t sz1 = (raw + 3) / 4, sz2 = (raw + 7) / 8;
                    d.seq = scr; P.nv.push_back({f, h1, (7ull << 56) | scr, sz1}); P.nv_key.push_back(key(0, t)); scr += al(sz1); f += h1;
                    d.cse = scr; P.nv.push_back({f, h2, (7ull << 56) | scr, sz2}); P.nv_key.push_back(key(0, t)); scr += al(sz2); f += h2;
                    if (h3) { d.gap = scr; P.nv.push_back({f, h3, (7ull << 56) | scr, (uint64_t)nexc * 4}); P.nv_key.push_back(key(0, t)); scr += al((uint64_t)nexc * 4); } f += h3;
                    if (h4) { d.val = scr; P.nv.push_back({f, h4, (7ull << 56) | scr, (uint64_t)nexc}); P.nv_key.push_back(key(0, t)); scr += al((uint64_t)nexc); }
                    if (nexc && (!h3 || !h4)) return E_STREAM;
                    P.dna.push_back(d); P.dna_key.push_back(t); continue;
                }
                P.nv.push_back({tagged ? cpos + 1 : cpos, tagged ? csz - 1 : csz, dst0, raw}); P.nv_key.push_back(key(0, t));
            }
        }
    }
    /* block table: every block's slices inside the stream sizes */
    for (uint32_t b = 0; b < P.nb; b++) {
        const uint8_t* e = &P.bo[64ull * b];
        for (int s = 0; s < 4; s++) { uint64_t o = rd64(e + 8 * s), n = rd64(e + 32 + 8 * s); if (o > P.ssz[s] || n > P.ssz[s] - o) return E_TABLE;
            if (b && o != rd64(e - 64 + 8 * s) + rd64(e - 64 + 32 + 8 * s)) P.contiguous = false; }
    }
    /* rANS pieces grouped by class, stable (keys keep (stream, chunk) order inside a class) */
    { std::vector<size_t> ix(P.rans.size()); for (size_t i = 0; i < ix.size(); i++) ix[i] = i;
      std::stable_sort(ix.begin(), ix.end(), [&](size_t x, size_t y) { return P.rans[x].pad < P.rans[y].pad; });
      std::vector<Rans> r(ix.size()); std::vector<uint64_t> k(ix.size());
      for (size_t i = 0; i < ix.size(); i++) { r[i] = P.rans[ix[i]]; k[i] = P.rans_key[ix[i]]; P.cls_off[r[i].pad + 1]++; }
      for (int q = 0; q < C_N; q++) P.cls_off[q + 1] += P.cls_off[q];
      P.rans.swap(r); P.rans_key.swap(k); }
    if (!P.nv.empty() && !nvt) return E_NVCOMP;
    for (auto& j : P.nv) { P.max_osz = std::max(P.max_osz, j.osz); P.nv_out_total += j.osz; }
    P.nv_temp = P.nv.empty() ? 0 : nvt(P.nv.size(), P.max_osz, P.nv_out_total);
    /* temp layout; region tags in bits 56..63 of the offsets above: 0..3 streams, 6 open scratch, 7 zstd DNA scratch */
    uint64_t t = 0;
    for (int s = 0; s < 4; s++) { P.o_s[s] = t; t += al(P.ssz[s] + 256); }
    P.o_scr = t; t += al(scr + 256); P.o_os = t; t += al(oscr + 256);
    P.o_ends = t; t += al(4 * (nends + 1)); P.o_nrun = t; t += al(4 * (P.open.size() + 1));
    P.o_err = t; t += 256; P.o_ctr = t; t += 256;
    const uint64_t N = P.nv.size();
    P.o_nvcp = t; t += al(8 * N + 8); P.o_nvop = t; t += al(8 * N + 8); P.o_nvcs = t; t += al(8 * N + 8);
    P.o_nvos = t; t += al(8 * N + 8); P.o_nvact = t; t += al(8 * N + 8); P.o_nvst = t; t += al(4 * N + 8);
    P.o_nvtmp = t; t += al(P.nv_temp + 256);
    P.o_rans = t; t += al(sizeof(Rans) * (P.rans.size() + 1)); P.o_open = t; t += al(sizeof(Open) * (P.open.size() + 1));
    P.o_dna = t; t += al(sizeof(Dna) * (P.dna.size() + 1));
    P.temp_bytes = t;
    /* resolve region tags into temp offsets (still relative to d_temp) */
    auto res = [&](uint64_t v) -> uint64_t { if (v == NUL) return NUL; uint64_t tag = v >> 56, o = v & ((1ull << 56) - 1);
        return (tag < 4 ? P.o_s[tag] : tag == 6 ? P.o_os : P.o_scr) + o; };
    for (auto& r : P.rans) r.dst = (r.pad == C_TOK) ? res(r.dst) : (r.pad == C_PLAIN ? P.o_s[0] + r.dst : res(r.dst));
    for (auto& r : P.raw) r.dst = res(r.dst);
    for (auto& j : P.nv) j.out_off = (j.out_off >> 56) ? res(j.out_off) : P.o_s[0] + j.out_off;
    for (auto& d : P.open) { d.seq += P.o_os; d.cse += P.o_os; d.gap += P.o_os; d.val += P.o_os; d.dst += P.o_s[0];
        d.ends = P.o_ends + 4 * d.ends; d.nrun = P.o_nrun + 4 * d.nrun; }
    for (auto& d : P.dna) { d.seq += P.o_scr; d.cse += P.o_scr; if (d.gap != NUL) d.gap += P.o_scr; if (d.val != NUL) d.val += P.o_scr; d.dst += P.o_s[0]; }
    return E_OK;
}

/* the jobs a range needs */
struct Sel {
    uint32_t b0 = 0, b1 = 0;                /* blocks */
    uint64_t win_off = 0;                   /* offset of the range inside the window of blocks b0.. */
    Seg nv_tok[4], nv_lit, rans_tok[4], rans_cls[C_N], open, dna, raw[4];
};
static inline Seg seg_of(const std::vector<uint64_t>& keys, size_t lo, size_t hi, uint64_t k0, uint64_t k1) {
    /* entries [lo,hi) of keys with k0 <= key <= k1 (keys ascending in [lo,hi)) */
    auto b = keys.begin();
    size_t i0 = std::lower_bound(b + lo, b + hi, k0) - b, i1 = std::upper_bound(b + lo, b + hi, k1) - b;
    return {(uint32_t)i0, (uint32_t)std::max(i0, i1)};
}
static inline uint64_t window_bytes(const Plan& P, uint64_t length) {
    return length ? al(((length - 1) / P.bs + 2) * (uint64_t)P.bs + 256) : 0;
}
static inline int select(const Plan& P, uint64_t off, uint64_t len, Sel& S) {
    S = Sel();
    if (len == 0 || off > P.orig || len > P.orig - off) return -1;
    if (!P.contiguous) return -2;
    S.b0 = (uint32_t)(off / P.bs); S.b1 = (uint32_t)((off + len - 1) / P.bs + 1); S.win_off = off - (uint64_t)S.b0 * P.bs;
    const uint8_t* e0 = &P.bo[64ull * S.b0]; const uint8_t* e1 = &P.bo[64ull * (S.b1 - 1)];
    uint64_t c0[4], c1[4]; bool any[4];
    for (int s = 0; s < 4; s++) {
        uint64_t lo = rd64(e0 + 8 * s), hi = rd64(e1 + 8 * s) + rd64(e1 + 32 + 8 * s);
        any[s] = hi > lo && P.chunk[s];
        c0[s] = any[s] ? lo / P.chunk[s] : 1; c1[s] = any[s] ? (hi - 1) / P.chunk[s] : 0;
    }
    for (int st = 1; st < 4; st++) {
        const uint64_t k0 = key(st, c0[st]), k1 = any[st] ? key(st, c1[st]) : 0;
        S.nv_tok[st] = any[st] ? seg_of(P.nv_key, 0, P.NT, k0, k1) : Seg{0, 0};
        S.rans_tok[st] = any[st] ? seg_of(P.rans_key, P.cls_off[C_TOK], P.cls_off[C_TOK + 1], k0, k1) : Seg{0, 0};
        S.raw[st] = any[st] ? seg_of(P.raw_key, 0, P.raw.size(), k0, k1) : Seg{0, 0};
    }
    if (any[0]) {
        const uint64_t k0 = key(0, c0[0]), k1 = key(0, c1[0]);
        S.nv_lit = seg_of(P.nv_key, P.NT, P.nv.size(), k0, k1);
        for (int q = C_SEQ; q < C_N; q++) S.rans_cls[q] = seg_of(P.rans_key, P.cls_off[q], P.cls_off[q + 1], k0, k1);
        S.open = seg_of(P.open_key, 0, P.open.size(), c0[0], c1[0]);
        S.dna = seg_of(P.dna_key, 0, P.dna.size(), c0[0], c1[0]);
    }
    return 0;
}
}  /* namespace agp */
#endif
