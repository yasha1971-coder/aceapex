// cnt.h - forced include (-include) for the COUNTING copy of the AGC 3.2.4 library sources (never the timed build):
// zstd calls of the library go through counting wrappers keyed by call site (file:line); agccnt_event() adds to named
// counters. Counters are thread-local and read by agccount.cpp around one agc_get_ctg_seq call.
#pragma once
#include <zstd/lib/zstd.h>
#include <cstdint>
ZSTD_DCtx* agccnt_createDCtx(const char* f, int l);
size_t agccnt_freeDCtx(ZSTD_DCtx* c, const char* f, int l);
size_t agccnt_decompressDCtx(ZSTD_DCtx* c, void* d, size_t dc, const void* s, size_t sc, const char* f, int l);
size_t agccnt_decompress(void* d, size_t dc, const void* s, size_t sc, const char* f, int l);
void agccnt_event(const char* name, uint64_t v);
#define ZSTD_createDCtx() agccnt_createDCtx(__FILE__, __LINE__)
#define ZSTD_freeDCtx(c) agccnt_freeDCtx((c), __FILE__, __LINE__)
#define ZSTD_decompressDCtx(c, d, dc, s, sc) agccnt_decompressDCtx((c), (d), (dc), (s), (sc), __FILE__, __LINE__)
#define ZSTD_decompress(d, dc, s, sc) agccnt_decompress((d), (dc), (s), (sc), __FILE__, __LINE__)
#define AGCCNT(name, v) agccnt_event(name, (uint64_t)(v))
