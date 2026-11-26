/* ax_zframe.h - zstd frame check before every decompression of archive bytes (2.6.5, SEC-ZSTD-1). C99 and C++.
 * One identical copy in src/, c/ and python/csrc/ (claim head_python_csrc_in_sync).
 *
 * ZSTD_decompress and ZSTD_decompressDCtx decode every frame of their input in turn, and a libzstd built with
 * ZSTD_LEGACY_SUPPORT (the system libzstd of Debian and Ubuntu: formats v0.5-v0.7; zstd < 1.6.0 builds by default)
 * hands a legacy frame to its v0.x decoder. ACEAPEX archives hold only zstd v1 frames, so each frame is checked
 * before libzstd sees the bytes: magic 0xFD2FB528 at its start, its size from ZSTD_findFrameCompressedSize (which
 * parses only the v1 header and block headers of a v1 frame). A legacy or skippable frame anywhere in the input, or a
 * truncated frame, fails the check; checking the first frame alone would let a legacy frame behind a valid one through.
 */
#ifndef AX_ZFRAME_H
#define AX_ZFRAME_H
#include <stddef.h>
#include <zstd.h>

/* 1 when src[0..n) is a sequence of zstd v1 frames, 0 otherwise. n == 0: no frame, 1 (decoding nothing gives 0 bytes) */
static inline int ax_zframes_ok(const void* src, size_t n) {
#ifdef AX_ZFRAME_NO_CHECK   /* negative control of verify/repro/zstd_legacy only: no check, every frame reaches libzstd */
    (void)src; (void)n; return 1;
#else
    const unsigned char* p = (const unsigned char*)src;
    size_t pos = 0;
    while (pos < n) {
        size_t sz;
        if (n - pos < 4 || p[pos] != 0x28 || p[pos + 1] != 0xB5 || p[pos + 2] != 0x2F || p[pos + 3] != 0xFD) return 0;
        sz = ZSTD_findFrameCompressedSize(p + pos, n - pos);
        if (ZSTD_isError(sz) || sz == 0 || sz > n - pos) return 0;
        pos += sz;
    }
    return 1;
#endif
}
#endif
