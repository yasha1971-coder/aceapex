// fuzz_region.cpp - libFuzzer harness over the C++ region paths (2.6.4 step 2): aceapex_decompress_region (an offset
// taken from the input and the first and last bytes), aceapex_decompress_ranges (3 ranges, 1 and 2 threads) and
// aceapex_decode_streams. The input is an archive (libFuzzer hands it in a heap buffer of exactly its size: ASan sees a
// read past it). fuzz_api covers decompress_mt and the stream decoder; until 2.6.4 nothing fuzzed these paths.
// Only the sanitizers judge: no checksum in this API, a success with other bytes is allowed. An allocation above the
// limit (ClusterFuzzLite: malloc_limit_mb in fuzz_region.options; locally ASAN_OPTIONS max_allocation_size_mb) is a crash.
#include "aceapex.h"
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    uint64_t orig = 4096;
    if (size >= 20) { uint64_t o; memcpy(&o, data + 12, 8); if (o) orig = o; }
    uint64_t h = 1469598103934665603ull; for (size_t i = 0; i < size && i < 64; i++) h = (h ^ data[i]) * 1099511628211ull;
    std::vector<uint8_t> buf(3 * 4096 + 64);
    const uint64_t off = h % orig, len = orig - off < 4096 ? orig - off : 4096;
    (void)aceapex_decompress_region(data, size, buf.data(), 4096, off, len ? len : 1);
    (void)aceapex_decompress_region(data, size, buf.data(), 4096, 0, 1);
    (void)aceapex_decompress_region(data, size, buf.data(), 4096, orig - 1, 1);
    for (int t = 1; t <= 2; t++) {
        aceapex_range_t rg[3] = {{off, len, buf.data(), 0}, {(h >> 20) % orig, 1, buf.data() + 4096, 0},
                                 {0, orig < 4096 ? orig : 4096, buf.data() + 8192, 0}};
        (void)aceapex_decompress_ranges(data, size, rg, 3, t);
    }
    aceapex_streams_t s;
    if (aceapex_decode_streams(data, size, &s) == 0) aceapex_streams_free(&s);
    return 0;
}
