#include "core.hpp"
#include "libsais.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <memory>
#include <new>
#include <stdexcept>
#include <utility>

namespace crown2 {
namespace {

constexpr uint32_t kRowLimit = uint32_t{1} << 24;
using Clock = std::chrono::steady_clock;

bool allowed_k(uint32_t k) {
    return k == 1 || k == 4 || k == 8 || k == 16 || k == 32;
}

uint32_t chain_count(uint32_t n, uint32_t k) {
    return std::min(n, k);
}

uint32_t boundary(uint32_t k, uint32_t n, uint32_t chains) {
    return static_cast<uint32_t>((uint64_t{k} * n) / chains);
}

uint64_t elapsed_ns(Clock::time_point begin, Clock::time_point end) {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(end - begin).count());
}

bool validate(const Image& image, std::string& error) {
    if (!allowed_k(image.requested_k)) {
        error = "unsupported chain count";
        return false;
    }
    if (image.n >= kRowLimit || image.bwt.size() != image.n) {
        error = "BWT size outside the packed-row format";
        return false;
    }
    const uint32_t chains = chain_count(image.n, image.requested_k);
    if (image.starts.size() != chains) {
        error = "incorrect number of sampled rows";
        return false;
    }
    if (image.n == 0) {
        if (image.primary != 0) {
            error = "nonzero primary row for empty input";
            return false;
        }
        return true;
    }
    if (image.primary == 0 || image.primary > image.n ||
        image.starts[0] != image.primary) {
        error = "invalid primary row";
        return false;
    }
    for (uint32_t k = 0; k < chains; ++k) {
        if (image.starts[k] == 0 || image.starts[k] > image.n) {
            error = "sampled row outside the permutation";
            return false;
        }
        for (uint32_t j = 0; j < k; ++j) {
            if (image.starts[j] == image.starts[k]) {
                error = "duplicate sampled row";
                return false;
            }
        }
    }
    return true;
}

template <bool Prefetch>
inline void prefetch_row(const uint32_t* links, uint32_t row) {
    if constexpr (Prefetch) {
#if defined(__GNUC__) || defined(__clang__)
        __builtin_prefetch(static_cast<const void*>(links + row), 0, 1);
#else
        (void)links;
        (void)row;
#endif
    } else {
        (void)links;
        (void)row;
    }
}

template <std::size_t K, bool Prefetch, std::size_t J>
inline bool step(const uint32_t* links, std::array<uint32_t, K>& rows,
                 std::array<uint8_t*, K>& destinations) {
    // Every table link is constructed in [0,n], so an initial validated row
    // cannot create an out-of-range access. Row 0 is the virtual sentinel and
    // must never be emitted as an ordinary byte, even for a malformed BWT.
    if (rows[J] == 0) {
        return false;
    }
    const uint32_t entry = links[rows[J]];
    *destinations[J]++ = static_cast<uint8_t>(entry);
    rows[J] = entry >> 8;
    prefetch_row<Prefetch>(links, rows[J]);
    return true;
}

template <std::size_t K, bool Prefetch, std::size_t... J>
inline bool round(const uint32_t* links, std::array<uint32_t, K>& rows,
                  std::array<uint8_t*, K>& destinations,
                  std::index_sequence<J...>) {
    // Explicit expansion gives the compiler independent, constant-index states
    // rather than a variable-index loop whose cursors may remain in memory.
    return (step<K, Prefetch, J>(links, rows, destinations) && ...);
}

template <std::size_t K, bool Prefetch>
bool walk(const Image& image, const uint32_t* links,
          std::vector<uint8_t>& decoded, std::string& error) {
    std::array<uint32_t, K> rows;
    std::array<uint8_t*, K> destinations;
    std::array<uint32_t, K> lengths;
    for (uint32_t k = 0; k < K; ++k) {
        const uint32_t begin = boundary(k, image.n, static_cast<uint32_t>(K));
        const uint32_t end = boundary(k + 1, image.n, static_cast<uint32_t>(K));
        rows[k] = image.starts[k];
        destinations[k] = decoded.data() + begin;
        lengths[k] = end - begin;
        prefetch_row<Prefetch>(links, rows[k]);
    }
    const uint32_t common = image.n / static_cast<uint32_t>(K);
    for (uint32_t position = 0; position < common; ++position) {
        if (!round<K, Prefetch>(links, rows, destinations,
                               std::make_index_sequence<K>{})) {
            error = "BWT chain reaches sentinel before its endpoint";
            return false;
        }
    }
    for (uint32_t k = 0; k < K; ++k) {
        // Balanced segment lengths differ by at most one. Short partial blocks
        // need at most this one final byte per longer segment.
        if (lengths[k] > common) {
            if (rows[k] == 0) {
                error = "BWT chain reaches sentinel before its endpoint";
                return false;
            }
            const uint32_t entry = links[rows[k]];
            *destinations[k]++ = static_cast<uint8_t>(entry);
            rows[k] = entry >> 8;
        }
        const uint32_t expected = k + 1 < K ? image.starts[k + 1] : 0;
        if (rows[k] != expected) {
            error = "BWT chain endpoint does not match the next segment";
            return false;
        }
    }
    return true;
}

// A requested K can exceed n only for tiny inputs. Keep their arbitrary actual
// chain count out of the performance-specialized kernels.
template <bool Prefetch>
bool walk_tiny(const Image& image, const uint32_t* links,
               std::vector<uint8_t>& decoded, std::string& error) {
    for (uint32_t k = 0; k < image.n; ++k) {
        const uint32_t row = image.starts[k];
        const uint32_t entry = links[row];
        decoded[k] = static_cast<uint8_t>(entry);
        const uint32_t next = entry >> 8;
        prefetch_row<Prefetch>(links, next);
        const uint32_t expected = k + 1 < image.n ? image.starts[k + 1] : 0;
        if (next != expected) {
            error = "tiny BWT chain endpoint mismatch";
            return false;
        }
    }
    return true;
}

template <bool Prefetch>
bool dispatch(const Image& image, const uint32_t* links,
              std::vector<uint8_t>& decoded, std::string& error) {
    if (image.n < image.requested_k) {
        return walk_tiny<Prefetch>(image, links, decoded, error);
    }
    switch (image.requested_k) {
        case 1: return walk<1, Prefetch>(image, links, decoded, error);
        case 4: return walk<4, Prefetch>(image, links, decoded, error);
        case 8: return walk<8, Prefetch>(image, links, decoded, error);
        case 16: return walk<16, Prefetch>(image, links, decoded, error);
        case 32: return walk<32, Prefetch>(image, links, decoded, error);
        default:
            error = "unsupported chain count";
            return false;
    }
}

}  // namespace

bool encode(const std::vector<uint8_t>& input, uint32_t requested_k,
            Image& output, std::string& error) {
    error.clear();
    if (!allowed_k(requested_k)) {
        error = "unsupported chain count";
        return false;
    }
    if (input.size() >= kRowLimit) {
        error = "input exceeds the packed-row block limit";
        return false;
    }
    try {
        Image image;
        image.n = static_cast<uint32_t>(input.size());
        image.requested_k = requested_k;
        if (image.n == 0) {
            output = std::move(image);
            return true;
        }
        std::vector<int32_t> sa(image.n);
        const int32_t status = libsais(input.data(), sa.data(),
                                      static_cast<int32_t>(image.n), 0, nullptr);
        if (status != 0) {
            error = "libsais suffix-array construction failed: " +
                    std::to_string(status);
            return false;
        }
        const uint32_t chains = chain_count(image.n, requested_k);
        std::array<uint32_t, 32> positions{};
        image.starts.assign(chains, 0);
        for (uint32_t k = 0; k < chains; ++k) {
            positions[k] = boundary(k, image.n, chains);
        }
        for (uint32_t rank = 0; rank < image.n; ++rank) {
            const int32_t position = sa[rank];
            if (position < 0 || static_cast<uint32_t>(position) >= image.n) {
                error = "libsais returned a suffix outside the input";
                return false;
            }
            const auto it = std::lower_bound(positions.begin(),
                                             positions.begin() + chains,
                                             static_cast<uint32_t>(position));
            if (it != positions.begin() + chains &&
                *it == static_cast<uint32_t>(position)) {
                image.starts[static_cast<std::size_t>(it - positions.begin())] =
                    rank + 1;
            }
        }
        image.primary = image.starts[0];
        image.bwt.resize(image.n);
        image.bwt[0] = input.back();
        // Sort T with a virtual unique end symbol smaller than all byte values.
        // Its empty suffix is row 0; real SA ranks occupy rows 1..n. The sole
        // sentinel in the last column is omitted at row `primary`, so binary
        // inputs need neither a reserved byte nor an alphabet escape.
        for (uint32_t rank = 0; rank < image.n; ++rank) {
            const uint32_t position = static_cast<uint32_t>(sa[rank]);
            if (position != 0) {
                const uint32_t row = rank + 1;
                const uint32_t stored = row - static_cast<uint32_t>(row > image.primary);
                image.bwt[stored] = input[position - 1];
            }
        }
        if (!validate(image, error)) {
            return false;
        }
        output = std::move(image);
        return true;
    } catch (const std::bad_alloc&) {
        error = "allocation failed during BWT encoding";
    } catch (const std::length_error&) {
        error = "allocation length invalid during BWT encoding";
    }
    return false;
}

bool decode(const Image& image, bool prefetch, std::vector<uint8_t>& output,
            std::string& error, Phases* phases) {
    error.clear();
    Clock::time_point begin;
    if (phases != nullptr) {
        *phases = {};
        begin = Clock::now();
    }
    if (!validate(image, error)) {
        return false;
    }
    try {
        if (image.n == 0) {
            output.clear();
            if (phases != nullptr) {
                phases->build_ns = elapsed_ns(begin, Clock::now());
            }
            return true;
        }
        std::array<uint32_t, 256> counts{};
        for (uint8_t c : image.bwt) {
            ++counts[c];
        }
        std::array<uint32_t, 256> cursor;
        uint32_t total = 1;  // Row 0 belongs to the virtual sentinel.
        for (uint32_t c = 0; c < 256; ++c) {
            cursor[c] = total;
            total += counts[c];
        }
        if (total != image.n + 1) {
            error = "BWT histogram length mismatch";
            return false;
        }
        // Each real row is assigned exactly once by stable counting. Avoid a
        // needless full-table zero fill; only the virtual sentinel is separate.
        std::unique_ptr<uint32_t[]> links(new uint32_t[std::size_t{image.n} + 1]);
        links[0] = 0;
        for (uint32_t j = 0; j < image.n; ++j) {
            const uint32_t c = image.bwt[j];
            const uint32_t row = j + static_cast<uint32_t>(j >= image.primary);
            const uint32_t first_column_row = cursor[c]++;
            links[first_column_row] = (row << 8) | c;
        }
        // Host comparisons prepare identical caller-owned buffers before the
        // timer for this decoder and the in-place reference decoder. resize()
        // is a no-op for an already-sized buffer; do not allocate a second one.
        output.resize(image.n);
        Clock::time_point walk_begin;
        if (phases != nullptr) {
            walk_begin = Clock::now();
            phases->build_ns = elapsed_ns(begin, walk_begin);
        }
        const bool success = prefetch
            ? dispatch<true>(image, links.get(), output, error)
            : dispatch<false>(image, links.get(), output, error);
        if (phases != nullptr) {
            phases->walk_ns = elapsed_ns(walk_begin, Clock::now());
        }
        if (!success) {
            return false;
        }
        return true;
    } catch (const std::bad_alloc&) {
        error = "allocation failed during BWT decoding";
    } catch (const std::length_error&) {
        error = "allocation length invalid during BWT decoding";
    }
    return false;
}

}  // namespace crown2
