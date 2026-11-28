#pragma once

#include <span>
#include <string>
#include <vector>

#if defined(__GNUC__) || defined(__clang__)
#define CROWN2_BASELINE_API __attribute__((visibility("default")))
#else
#define CROWN2_BASELINE_API
#endif

namespace crown2 {

// Only BWT bytes and the public libbsc BWT API's primary/secondary indexes.
// This is a research phase image, not a compressed bsc archive.
struct BaselineImage {
    std::vector<unsigned char> bwt;
    int primary = 0;
    std::vector<int> indexes;
};

[[nodiscard]] CROWN2_BASELINE_API bool baseline_encode(
    std::span<const unsigned char> input, BaselineImage& image,
    std::string& error);

// The public bsc inverse API mutates its BWT argument. This wrapper copies that
// argument into out; timing this function includes that copy and allocation.
[[nodiscard]] CROWN2_BASELINE_API bool baseline_decode(
    const BaselineImage& image, std::vector<unsigned char>& out,
    std::string& error);

// Timed phase entry: working must already contain image.bwt, prepared outside
// the timer. Its size is checked here; equality is the untimed caller's duty.
// The library still allocates/releases its inverse workspace inside this call.
[[nodiscard]] CROWN2_BASELINE_API bool baseline_decode_inplace(
    const BaselineImage& image, std::vector<unsigned char>& working,
    std::string& error);

}  // namespace crown2
