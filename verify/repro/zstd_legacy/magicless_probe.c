/* magicless_probe.c - why SEC-ZSTD-1 does not decode in magicless mode (2.6.5): a DCtx with
 * ZSTD_d_format = ZSTD_f_zstd1_magicless does NOT keep legacy frames away from the legacy decoder in every libzstd.
 * zstd 1.4.8, lib/decompress/zstd_decompress.c:725, ZSTD_decompressMultiFrame calls ZSTD_isLegacy(src, srcSize)
 * without looking at dctx->format; 1.5.x and 1.6.0 test dctx->format == ZSTD_f_zstd1 first. Inputs from
 * zl_v1_v07.aet: the chunk is a 25-byte v1 frame of 16 bytes ("A" x 16) followed by the 178-byte v0.7 frame.
 *   case 1: the v0.7 frame alone, magicless DCtx
 *   case 2: the v1 frame without its 4 magic bytes, then the v0.7 frame (what a magicless reader would hand over)
 * Prints for each case the return value and whether the legacy decoder produced the v0.7 text (239 bytes of it).
 * Not a judge claim: the outcome depends on the libzstd it is linked with (and on ZSTD_LEGACY_SUPPORT in it).
 * Build: cc -std=c99 -O1 -o magicless_probe magicless_probe.c -lzstd ; run: ./magicless_probe <dir of this directory>
 */
#define ZSTD_STATIC_LINKING_ONLY
#include <zstd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char** argv) {
    char p[4096]; FILE* f; unsigned char a[4096], out[4096], in[512]; size_t an, r, n; const unsigned char* chunk;
    ZSTD_DCtx* dc;
    if (argc < 2) return 2;
    snprintf(p, sizeof p, "%s/zl_v1_v07.aet", argv[1]); f = fopen(p, "rb"); if (!f) return 2;
    an = fread(a, 1, sizeof a, f); fclose(f);
    chunk = a + 68 + 64 + 24;                       /* header, block entry, literal stream head; chunk = 25 + 178 bytes */
    if (an < 68 + 64 + 24 + 25 + 178 || chunk[0] != 0x28 || chunk[25] != 0x27) { printf("unexpected input\n"); return 2; }
    printf("libzstd %s\n", ZSTD_versionString());
    dc = ZSTD_createDCtx();
    if (ZSTD_isError(ZSTD_DCtx_setParameter(dc, ZSTD_d_format, ZSTD_f_zstd1_magicless))) { printf("magicless not supported\n"); return 2; }
    r = ZSTD_decompressDCtx(dc, out, sizeof out, chunk + 25, 178);
    printf("case 1 (v0.7 frame, magicless DCtx): %s%s\n", ZSTD_isError(r) ? ZSTD_getErrorName(r) : "decoded ",
           ZSTD_isError(r) ? "" : (r == 239 ? "239 bytes - the legacy decoder ran" : "other size"));
    n = 21 + 178; memcpy(in, chunk + 4, 21); memcpy(in + 21, chunk + 25, 178);
    r = ZSTD_decompressDCtx(dc, out, sizeof out, in, n);
    printf("case 2 (magicless v1 frame + v0.7 frame): %s%s\n", ZSTD_isError(r) ? ZSTD_getErrorName(r) : "decoded ",
           ZSTD_isError(r) ? "" : (r == 16 + 239 ? "255 bytes - the legacy decoder ran on the second frame" : "other size"));
    ZSTD_freeDCtx(dc);
    return 0;
}
