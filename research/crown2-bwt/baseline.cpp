#include "baseline.hpp"

#include <libbsc/bwt/bwt.h>
#include <libbsc/libbsc.h>

#include <array>
#include <exception>
#include <limits>
#include <utility>

namespace crown2 {
namespace {

bool initialize(std::string& error) {
    // No FASTMODE, MULTITHREADING, LARGEPAGES or CUDA feature is requested.
    static const int status = bsc_init(LIBBSC_FEATURE_NONE);
    if (status != LIBBSC_NO_ERROR) {
        error = "bsc_init failed: " + std::to_string(status);
        return false;
    }
    return true;
}

}  // namespace

bool baseline_encode(std::span<const unsigned char> input,
                     BaselineImage& image, std::string& error) {
    error.clear();
    if (input.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        error = "baseline input exceeds the public libbsc int length";
        return false;
    }
    try {
        if (!initialize(error)) return false;
        BaselineImage result;
        result.bwt.assign(input.begin(), input.end());
        if (input.empty()) {
            // An explicit identity control; it is not a measured BWT call.
            image = std::move(result);
            return true;
        }
        std::array<int, 256> secondary{};
        unsigned char count = 0;
        const int primary = bsc_bwt_encode(
            result.bwt.data(), static_cast<int>(result.bwt.size()),
            &count, secondary.data(), LIBBSC_FEATURE_NONE);
        if (primary < 0) {
            error = "bsc_bwt_encode failed: " + std::to_string(primary);
            return false;
        }
        result.primary = primary;
        result.indexes.assign(secondary.begin(), secondary.begin() + count);
        image = std::move(result);
        return true;
    } catch (const std::exception& ex) {
        error = std::string("baseline encode exception: ") + ex.what();
        return false;
    }
}

bool baseline_decode_inplace(const BaselineImage& image,
                             std::vector<unsigned char>& out,
                             std::string& error) {
    error.clear();
    const std::size_t size = image.bwt.size();
    if (size > static_cast<std::size_t>(std::numeric_limits<int>::max()) ||
        image.indexes.size() > 255) {
        error = "baseline image exceeds the public libbsc length/count";
        return false;
    }
    if (out.size() != size) {
        error = "baseline working buffer has the wrong length";
        return false;
    }
    if (size == 0) {
        if (image.primary != 0 || !image.indexes.empty()) {
            error = "nonempty baseline index metadata for empty input";
            return false;
        }
        out.clear();
        return true;
    }
    if (image.primary < 1 || static_cast<std::size_t>(image.primary) > size) {
        error = "baseline primary index is outside the BWT rows";
        return false;
    }
    for (int index : image.indexes) {
        if (index < 0 || static_cast<std::size_t>(index) >= size) {
            error = "baseline secondary index is outside the BWT rows";
            return false;
        }
    }
    try {
        if (!initialize(error)) return false;
        // bsc_bwt_decode's public signature takes a mutable indexes pointer.
        // A local copy also protects the retained phase image from mutation.
        std::array<int, 256> secondary{};
        for (std::size_t i = 0; i < image.indexes.size(); ++i) {
            secondary[i] = image.indexes[i];
        }
        const int status = bsc_bwt_decode(
            out.data(), static_cast<int>(size), image.primary,
            static_cast<unsigned char>(image.indexes.size()),
            image.indexes.empty() ? nullptr : secondary.data(),
            LIBBSC_FEATURE_NONE);
        if (status != LIBBSC_NO_ERROR) {
            out.clear();
            error = "bsc_bwt_decode failed: " + std::to_string(status);
            return false;
        }
        return true;
    } catch (const std::exception& ex) {
        out.clear();
        error = std::string("baseline decode exception: ") + ex.what();
        return false;
    }
}

bool baseline_decode(const BaselineImage& image,
                     std::vector<unsigned char>& out, std::string& error) {
    try {
        out.assign(image.bwt.begin(), image.bwt.end());
        return baseline_decode_inplace(image, out, error);
    } catch (const std::exception& ex) {
        out.clear();
        error = std::string("baseline decode preparation exception: ") + ex.what();
        return false;
    }
}

}  // namespace crown2
