#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ACEAPEX_VERSION_MAJOR 2
#define ACEAPEX_VERSION_MINOR 0

/* One-shot compression */
int64_t aceapex_compress(
    const void* src, size_t src_size,
    void*       dst, size_t dst_capacity,
    int         level,    /* 1=fast, 2=default */
    int         threads   /* 0=auto */
);

/* One-shot decompression */
int64_t aceapex_decompress(
    const void* src, size_t src_size,
    void*       dst, size_t dst_capacity
);

/* Decompress only the bytes [offset, offset+length) of the original input,
   without decoding the rest of the archive. dst must hold at least length bytes.
   Returns length on success, or a negative error code.

   Cost is set by the block size and, for archives written with chunked literals,
   by the chunk size: the decoder touches the blocks covering the range and, in
   each of the four streams, only the compressed chunks those blocks fall into.
   Both are recorded in the archive; nothing is read from the environment. */
int64_t aceapex_decompress_region(
    const void* src, size_t src_size,
    void*       dst, size_t dst_capacity,
    uint64_t    offset, uint64_t length
);

/* Bound for output buffer */
size_t aceapex_compress_bound(size_t src_size);

/* Streaming context (v2.0) */
typedef struct aceapex_stream_s aceapex_stream_t;

aceapex_stream_t* aceapex_stream_new(int level, int threads);
int  aceapex_stream_update(aceapex_stream_t* s,
                           const void* in,  size_t in_size,
                           void*       out, size_t out_capacity,
                           size_t*     out_written);
int  aceapex_stream_finish(aceapex_stream_t* s,
                           void*   out, size_t out_capacity,
                           size_t* out_written);
void aceapex_stream_free(aceapex_stream_t* s);

/* Error codes */
#define ACEAPEX_OK           0
#define ACEAPEX_ERR_BUFFER  -1
#define ACEAPEX_ERR_DATA    -2
#define ACEAPEX_ERR_MEMORY  -3

#ifdef __cplusplus
}
#endif
