#ifndef CROWN2_BWT_CORE_HPP
#define CROWN2_BWT_CORE_HPP

#include <cstdint>
#include <string>
#include <vector>

namespace crown2 {

// Research image, not a complete compressed archive. The caller's container
// protects all fields and payload with its checksum and accounts for their size.
struct Image {
    uint32_t n = 0;
    uint32_t primary = 0;
    uint32_t requested_k = 1;
    std::vector<uint8_t> bwt;
    std::vector<uint32_t> starts;
};

struct Phases {
    uint64_t build_ns = 0;
    uint64_t walk_ns = 0;
};

// Allowed requested_k: 1, 4, 8, 16, 32. The format requires n < 2^24.
// Segment boundaries are floor(k*n/min(n,requested_k)); empty input has no
// segments, primary=0 and an empty BWT. Outputs change only on success.
bool encode(const std::vector<uint8_t>& input, uint32_t requested_k,
            Image& output, std::string& error);

// Includes validation, workspace allocation, histogram, permutation construction
// and chain traversal. phases=nullptr makes no internal clock calls. A caller
// measuring the complete phase must time this entire function, not just walk_ns.
// An already-sized output buffer is reused without allocating or clearing it.
// On failure output may contain partial decoded bytes and must not be used.
bool decode(const Image& image, bool prefetch, std::vector<uint8_t>& output,
            std::string& error, Phases* phases = nullptr);

}  // namespace crown2

#endif
