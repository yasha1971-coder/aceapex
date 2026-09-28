/* aceapex_decode.h - standalone C99 decoder for ACEPX2 archives (.aet).
 *
 * One translation unit, one dependency (libzstd), no threads, no globals. Meant for
 * embedding: a database, a bioinformatics tool or a language binding links this file
 * and reads regions of an archive without the ACEAPEX CLI or its C++ library.
 * The functions mirror aceapex.h (same names, same error codes) so a caller can swap
 * between this file and the full library. Encoding is not provided here.
 */
#ifndef ACEAPEX_DECODE_H
#define ACEAPEX_DECODE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

#define ACEAPEX_OK           0
#define ACEAPEX_ERR_BUFFER  -1
#define ACEAPEX_ERR_DATA    -2
#define ACEAPEX_ERR_MEMORY  -3

/* Size of the original input recorded in the archive, or a negative error code. */
int64_t aceapex_decoded_size(const void* src, size_t src_size);

/* Whole archive -> dst. Returns bytes written or a negative error code. */
int64_t aceapex_decompress(const void* src, size_t src_size, void* dst, size_t dst_capacity);

/* Bytes [offset, offset+length) of the original input, touching only the blocks that
 * cover the range and, in each stream, only the compressed chunks those blocks use. */
int64_t aceapex_decompress_region(const void* src, size_t src_size, void* dst,
                                  size_t dst_capacity, uint64_t offset, uint64_t length);

/* Many ranges from one archive: each distinct block is decoded once and sliced.
 * 'written' receives the byte count per entry, or a negative code for that entry.
 * Returns the number of entries that succeeded, or a negative code for a bad archive. */
typedef struct {
    uint64_t offset;
    uint64_t length;
    void*    dst;
    int64_t  written;
} aceapex_range_t;
int64_t aceapex_decompress_ranges(const void* src, size_t src_size,
                                  aceapex_range_t* ranges, size_t count, int threads);

#ifdef __cplusplus
}
#endif
#endif
