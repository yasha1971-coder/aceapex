// w1_wall.cpp - W1: where the FAST decoder's single-core wall is, and whether removing the read-for-ownership of the
// output moves it. One file, one core (pin it: taskset -c 2), median of R runs, every run compared with the input.
//
//   E0  memory or core?   decode the whole input into a buffer the size of the input (DRAM, as lzbench does), then
//                         the first blocks only, repeatedly, into a buffer that stays in L2/L3 (8 MiB). If the
//                         cache-resident decode is much faster, one core is bound by memory traffic, not by work.
//   memcpy                the same input copied into the same buffer: the reference lzbench prints as `memcpy`.
//   base                  axf_dec_block (src/ax_fast.h) straight into the output: 1 B written + ~1 B read for
//                         ownership + ratio B read per output byte.
//   clz                   the same decoder with CLZERO (AMD Zen, CPUID 8000_0008 EBX[0]) on the output lines a short
//                         distance ahead of the write pointer: the line is allocated zeroed in the cache, no read from
//                         DRAM, and stays in the cache for the matches that read it back. Skipped when the CPU lacks it.
//   nt                    every block decoded into a per-thread scratch buffer (cache-resident), then streamed to the
//                         output with non-temporal stores: no read for ownership, portable to Intel; costs one copy
//                         from cache. Run with block sizes 1 MiB and 256 KiB (the scratch must fit L2 to pay off).
//
// The archive is built here with axf::enc_block at the given level and block size (default level 1 = min match 16),
// the same encoder as `aceapex c --level 11`. Not a library path: a measurement tool (claim W1, results/w1-*.log).
// Build: g++ -O3 -std=c++17 -Isrc -o w1_wall scripts/w1_wall.cpp     (plain -O3, as lzbench builds; add -mavx2 to compare)
// Usage: w1_wall file [level=1] [block_KiB=1024] [reps=7] [ahead=512]
#include "ax_fast_enc.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <chrono>
#include <algorithm>
#include <immintrin.h>
#include <thread>
#if defined(__x86_64__)
#include <cpuid.h>
#endif
static double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static bool has_clzero() {
#if defined(__x86_64__)
    unsigned a, b, c, d; if (!__get_cpuid(0x80000000u, &a, &b, &c, &d) || a < 0x80000008u) return false;
    __cpuid(0x80000008u, a, b, c, d); return (b & 1u) != 0;
#else
    return false;
#endif
}
static inline void clzero_line(void* p) {
#if defined(__x86_64__)
    __asm__ volatile(".byte 0x0f, 0x01, 0xfc" : : "a"(p) : "memory");   // clzero [rax]: the 64-byte line holding rax
#else
    (void)p;
#endif
}

// The decoder of src/ax_fast.h (guarded runs) with one hook: before each run, CLZERO the whole lines of
// [zhi, min(d + AHEAD + run bytes, line-aligned end)) not yet zeroed. Lines are zeroed only inside [dst, dst + n)
// and only whole lines; a line the decoder already wrote is never zeroed (zhi only moves forward from d).
template <bool CLZ>
static uint32_t dec_block_w(const uint8_t* src, size_t ssz, uint8_t* dst, uint32_t n, const uint32_t mm, size_t ahead) {
    uint32_t ntok, next, tail, i;
    const uint8_t *tp, *ext, *lit, *lend, *eend; uint8_t *d, *dend;
    if (ssz < AXF_BHDR + AXF_PAD) return 0;
    ntok = axf_rd32(src); next = axf_rd32(src + 4); tail = axf_rd32(src + 8);
    if ((uint64_t)AXF_BHDR + 4ull * ntok + next + AXF_PAD > ssz) return 0;
    tp = src + AXF_BHDR; ext = tp + 4ull * ntok; lit = ext + next; eend = lit; lend = src + ssz - AXF_PAD;
    d = dst; dend = dst + n;
    uint8_t* zhi = (uint8_t*)(((uintptr_t)dst + 63) & ~(uintptr_t)63);                 // first whole line
    uint8_t* const zend = (uint8_t*)((uintptr_t)dend & ~(uintptr_t)63);                // end of the last whole line
    for (i = 0; i < ntok; ) {
        uint32_t k = ntok - i;
        { const size_t kd = (size_t)(dend - d) / AXF_ROOM, kl = (size_t)(lend - lit) / 62u + 1u;
          if (kd < k) k = (uint32_t)kd;
          if (kl < k) k = (uint32_t)kl; }
        if (CLZ) {   // a run of k tokens writes at most 160 k bytes from d
            if (zhi < d) zhi = (uint8_t*)(((uintptr_t)d + 63) & ~(uintptr_t)63);
            uint8_t* want = d + std::min<size_t>((size_t)(dend - d), ahead + (size_t)k * AXF_ROOM);
            if (want > zend) want = zend;
            for (; zhi + 64 <= want; zhi += 64) clzero_line(zhi);
        }
        for (; k; k--, i++) {
            const uint32_t t = axf_rd32(tp + 4ull * i);
            const uint32_t ll = t & 63u, mc = (t >> 6) & 63u, dist = (t >> 12) + AXF_MIN_DIST;
            if (AXF_UNLIKELY(ll == 63u || mc == 63u)) break;
            axf_cp32(d, lit); if (ll > 32u) axf_cp32(d + 32, lit + 32);
            d += ll; lit += ll;
            if (AXF_UNLIKELY((size_t)(d - dst) < dist)) return 0;
            axf_cpw(d, d - dist, mc + mm); d += mc + mm;
        }
        if (AXF_UNLIKELY(lit > lend)) return 0;
        if (i >= ntok) break;
        {   const uint32_t t = axf_rd32(tp + 4ull * i); uint32_t ll = t & 63u, mc = (t >> 6) & 63u, ml; const uint32_t dist = (t >> 12) + AXF_MIN_DIST;
            i++; int bad = 0; uint32_t c0;
            if (ll == 63u) { ll += axf_ext(&ext, eend, &bad); if (bad) return 0; }
            if ((size_t)(lend - lit) < ll || (size_t)(dend - d) < ll) return 0;
            if (CLZ) { uint8_t* want = std::min(d + ll + ahead, zend); if (zhi < d) zhi = (uint8_t*)(((uintptr_t)d + 63) & ~(uintptr_t)63); for (; zhi + 64 <= want; zhi += 64) clzero_line(zhi); }
            memcpy(d, lit, ll); d += ll; lit += ll;
            if ((size_t)(d - dst) < dist) return 0;
            ml = mc + mm; if (mc == 63u) { ml = AXF_COPY + 1 + axf_ext(&ext, eend, &bad); if (bad) return 0; }
            if ((size_t)(dend - d) < ml) return 0;
            if (CLZ) { uint8_t* want = std::min(d + ml + ahead, zend); if (zhi < d) zhi = (uint8_t*)(((uintptr_t)d + 63) & ~(uintptr_t)63); for (; zhi + 64 <= want; zhi += 64) clzero_line(zhi); }
            for (c0 = 0; c0 < ml; ) { uint32_t c = ml - c0 < dist ? ml - c0 : dist; memcpy(d + c0, d + c0 - dist, c); c0 += c; }
            d += ml;
        }
    }
    if ((size_t)(lend - lit) != tail || (size_t)(dend - d) != tail) return 0;
    memcpy(d, lit, tail);
    return n;
}
static void nt_copy(uint8_t* d, const uint8_t* s, size_t n) {   // head/tail by memcpy, the aligned middle with 16-byte NT stores
    size_t h = (16 - ((uintptr_t)d & 15)) & 15; if (h > n) h = n; memcpy(d, s, h); d += h; s += h; n -= h;
    for (; n >= 64; n -= 64, d += 64, s += 64) {
        const __m128i a = _mm_loadu_si128((const __m128i*)s), b = _mm_loadu_si128((const __m128i*)(s + 16)),
                      c = _mm_loadu_si128((const __m128i*)(s + 32)), e = _mm_loadu_si128((const __m128i*)(s + 48));
        _mm_stream_si128((__m128i*)d, a); _mm_stream_si128((__m128i*)(d + 16), b); _mm_stream_si128((__m128i*)(d + 32), c); _mm_stream_si128((__m128i*)(d + 48), e); }
    memcpy(d, s, n);
}

struct Arc { std::vector<uint8_t> z; std::vector<uint64_t> off; uint32_t bs, nb, mm; size_t orig; };
static Arc build(const std::vector<uint8_t>& in, int level, uint32_t bs) {
    Arc a; axf::Params P; axf::level_params(level, P); a.bs = bs; a.mm = P.mm; a.orig = in.size();
    a.nb = (uint32_t)((in.size() + bs - 1) / bs); a.off.resize(a.nb + 1);
    std::vector<std::vector<uint8_t>> blocks(a.nb);
    axf::Job j; j.src = in.data(); j.n = in.size(); j.bs = bs; j.nb = a.nb; j.P = P; j.blocks = &blocks; j.next = 0; j.err = 0;
    std::vector<std::thread> th; const int T = 8; for (int t = 0; t < T; t++) th.emplace_back([&] { axf::enc_worker(&j); }); for (auto& x : th) x.join();
    size_t o = 0; for (uint32_t b = 0; b < a.nb; b++) { a.off[b] = o; o += blocks[b].size(); } a.off[a.nb] = o;
    a.z.resize(o); for (uint32_t b = 0; b < a.nb; b++) memcpy(a.z.data() + a.off[b], blocks[b].data(), blocks[b].size());
    return a;
}
static inline uint32_t blen(const Arc& a, uint32_t b) { size_t st = (size_t)b * a.bs; return (uint32_t)std::min<size_t>(a.bs, a.orig - st); }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s file [level=1] [block_KiB=1024] [reps=7] [ahead=512]\n", argv[0]); return 1; }
    FILE* f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END); size_t n = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> in(n); if (fread(in.data(), 1, n, f) != n) return 1; fclose(f);
    const int level = argc > 2 ? atoi(argv[2]) : 1; const uint32_t bs = (argc > 3 ? (uint32_t)atoi(argv[3]) : 1024u) * 1024u;
    const int R = argc > 4 ? atoi(argv[4]) : 7; const size_t ahead = argc > 5 ? (size_t)atoi(argv[5]) : 512;
    if (bs > AXF_BLOCK_MAX || bs < 4096) { fprintf(stderr, "block 4..1024 KiB\n"); return 1; }
    Arc a = build(in, level, bs);
    printf("W1 %s: %zu B, level %d (min match %u), %u blocks of %u KiB -> %zu B = %.2f %%; reps %d, CLZERO %s, ahead %zu\n",
           argv[1], n, level, a.mm, a.nb, bs >> 10, a.z.size(), 100.0 * a.z.size() / n, R, has_clzero() ? "yes" : "no", ahead);
    uint8_t* out = (uint8_t*)aligned_alloc(64, (n + 63) & ~(size_t)63); memset(out, 0, n);     // touched once, as lzbench's buffer
    uint8_t* scratch = (uint8_t*)aligned_alloc(64, ((size_t)bs + 63) & ~(size_t)63); memset(scratch, 0, bs);
    auto run = [&](const char* name, auto&& body, size_t bytes, bool check_all) {
        std::vector<double> ts; bool ok = true;
        for (int r = 0; r < R; r++) { if (check_all) memset(out, 0xEE, n);
            const double t0 = now(); ok = body() && ok; ts.push_back(now() - t0);
            if (check_all) ok = ok && memcmp(out, in.data(), n) == 0; }
        std::sort(ts.begin(), ts.end());
        printf("%-34s %8.0f MB/s  (median of %d, best %.0f)  %s\n", name, bytes / ts[R / 2] / 1e6, R, bytes / ts[0] / 1e6, ok ? "bit-perfect" : "MISMATCH");
        return ok;
    };
    bool all = true;
    all &= run("memcpy (DRAM)", [&] { memcpy(out, in.data(), n); return true; }, n, true);
    all &= run("base: decode -> DRAM buffer", [&] { for (uint32_t b = 0; b < a.nb; b++) if (!dec_block_w<false>(a.z.data() + a.off[b], a.off[b + 1] - a.off[b], out + (size_t)b * bs, blen(a, b), a.mm, 0)) return false; return true; }, n, true);
    {   // E0: the first blocks (<= 8 MiB of output) decoded 16 times into the same cache-resident output
        const uint32_t kb = std::max<uint32_t>(1, std::min<uint32_t>(a.nb, (8u << 20) / bs)); size_t sb = 0; for (uint32_t b = 0; b < kb; b++) sb += blen(a, b);
        all &= run("E0: decode -> cache-resident 8 MiB", [&] { for (int rep = 0; rep < 16; rep++) for (uint32_t b = 0; b < kb; b++) if (!dec_block_w<false>(a.z.data() + a.off[b], a.off[b + 1] - a.off[b], out + (size_t)b * bs, blen(a, b), a.mm, 0)) return false;
                                                         return memcmp(out, in.data(), sb) == 0; }, 16 * sb, false);
    }
    if (has_clzero())
        all &= run("clz: CLZERO ahead -> DRAM buffer", [&] { for (uint32_t b = 0; b < a.nb; b++) if (!dec_block_w<true>(a.z.data() + a.off[b], a.off[b + 1] - a.off[b], out + (size_t)b * bs, blen(a, b), a.mm, ahead)) return false; return true; }, n, true);
    else printf("%-34s skipped: no CLZERO on this CPU\n", "clz: CLZERO ahead -> DRAM buffer");
    all &= run("nt: scratch + NT stream -> DRAM", [&] { for (uint32_t b = 0; b < a.nb; b++) { const uint32_t k = blen(a, b);
                                                          if (!dec_block_w<false>(a.z.data() + a.off[b], a.off[b + 1] - a.off[b], scratch, k, a.mm, 0)) return false;
                                                          nt_copy(out + (size_t)b * bs, scratch, k); } _mm_sfence(); return true; }, n, true);
    printf("W1 %s\n", all ? "all runs bit-perfect" : "MISMATCH");
    free(out); free(scratch); return all ? 0 : 1;
}
