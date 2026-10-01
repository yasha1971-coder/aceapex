/* aceapex_gpu.h - GPU decoder of ACEPX2 archives, C ABI (gate 5; docs/GPU_API.md).
 *
 * Two phases, as batched GPU codecs do:
 *   1. on the host, once per archive: aceapex_gpu_plan_create parses the header and every chunk table of a
 *      host copy of the archive, checks the framing and uploads its job tables to the device (the only
 *      allocation and the only copy this library makes on its own).
 *   2. on a stream, as often as needed: aceapex_gpu_decompress_async / _range_async launch the decode of a
 *      device copy of the same archive. They allocate nothing, copy nothing from the host and never
 *      synchronize; the caller provides the temp buffer. The result is valid when the stream reaches it.
 *
 * Fail-closed: framing errors are found by plan_create (NULL, see aceapex_gpu_last_error). Content errors
 * found on the device - a rANS piece, an open DNA pack, a zstd frame or a block whose tokens do not decode
 * to its size - are reported in *d_status (device memory, one int, written at the end of the call; 0 =
 * success, else a bitmask of ACEAPEX_GPU_STATUS_*). A decode never reads or writes outside the buffers it
 * was given. Bytes stored raw inside the archive (literal runs, raw pieces, zstd raw blocks) carry no check
 * of their own: only the archive's XXH3 of the whole original catches them - flag ACEAPEX_GPU_VERIFY_XXH3
 * computes it on the device (ACEAPEX_GPU_STATUS_HASH). A range decode cannot check it (the hash covers the
 * whole original).
 *
 * Buffers: d_in = the archive bytes (in_bytes, any alignment); d_temp = aceapex_gpu_temp_bytes() bytes
 * (range: aceapex_gpu_range_temp_bytes()), 256-byte aligned (cudaMalloc is); d_out = the original
 * (aceapex_gpu_output_bytes()) or the range (length bytes). One temp buffer per call in flight.
 * A plan is read-only after creation: several streams may use it at once, each with its own temp.
 * Archives of every profile; zstd frames (the default and rANS-token profiles) need the library built
 * with nvCOMP (-DACEAPEX_GPU_NVCOMP), the open profile (AX_PROFILE=open) needs nothing but CUDA.
 */
#ifndef ACEAPEX_GPU_H
#define ACEAPEX_GPU_H
#include <stddef.h>
#include <stdint.h>
#include <cuda_runtime_api.h>   /* cudaStream_t */
#ifdef __cplusplus
extern "C" {
#endif

typedef struct aceapex_gpu_plan aceapex_gpu_plan;

/* return codes of the host calls (and aceapex_gpu_last_error after a NULL plan) */
#define ACEAPEX_GPU_OK          0
#define ACEAPEX_GPU_E_ARGS     -1   /* null pointer, temp not 256-aligned, empty or out-of-range region */
#define ACEAPEX_GPU_E_ARCHIVE  -2   /* header, block table or chunk framing invalid */
#define ACEAPEX_GPU_E_NVCOMP   -3   /* the archive has zstd frames and the library was built without nvCOMP */
#define ACEAPEX_GPU_E_CUDA     -4   /* a CUDA call failed (allocation or launch) */
#define ACEAPEX_GPU_E_RANGE    -5   /* region reads need block slices laid out back to back (every encoder writes them so) */

/* *d_status after a decode: 0 or a bitmask */
#define ACEAPEX_GPU_STATUS_PIECE   1   /* a rANS token chunk or piece failed its checks (spec 3.1.1) */
#define ACEAPEX_GPU_STATUS_OPEN    2   /* an open DNA pack failed its checks (spec 3.4) */
#define ACEAPEX_GPU_STATUS_ZSTD    4   /* a zstd frame failed or decoded to another size */
#define ACEAPEX_GPU_STATUS_MATCH   8   /* a block's tokens did not decode to exactly its size */
#define ACEAPEX_GPU_STATUS_HASH   16   /* ACEAPEX_GPU_VERIFY_XXH3: XXH3_64bits of the output != the archive header */
#define ACEAPEX_GPU_STATUS_LIMIT  32   /* a kernel loop hit its step limit (a broken invariant: stopped, output invalid) */

/* flags of aceapex_gpu_decompress_async */
#define ACEAPEX_GPU_VERIFY_XXH3    1   /* hash the whole output on the device and compare with the header (full decode only) */

aceapex_gpu_plan* aceapex_gpu_plan_create(const void* h_archive, size_t in_bytes);
int     aceapex_gpu_last_error(void);                        /* of the last plan_create on this thread */
size_t  aceapex_gpu_temp_bytes(const aceapex_gpu_plan* plan);
size_t  aceapex_gpu_range_temp_bytes(const aceapex_gpu_plan* plan, uint64_t max_length);
size_t  aceapex_gpu_output_bytes(const aceapex_gpu_plan* plan);

int aceapex_gpu_decompress_async(const aceapex_gpu_plan* plan, const void* d_in,
                                 void* d_out, void* d_temp, int* d_status, unsigned flags, cudaStream_t stream);

/* bytes [offset, offset+length) of the original into d_out (length bytes): only the blocks covering the
   range and, in each stream, only the chunks those blocks use are decoded */
int aceapex_gpu_decompress_range_async(const aceapex_gpu_plan* plan, const void* d_in,
                                       uint64_t offset, uint64_t length,
                                       void* d_out, void* d_temp, int* d_status, cudaStream_t stream);

void aceapex_gpu_plan_destroy(aceapex_gpu_plan* plan);

#ifdef __cplusplus
}
#endif
#endif
