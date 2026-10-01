// gpu_abi_test.cpp - the host-only part of the GPU C ABI (src/aceapex_gpu_abi.cpp) without CUDA: the plan builder
// is replaced by a stub that records its call. Checks: every bit outside ACEAPEX_GPU_PLAN_FLAGS (and a null archive)
// is refused with ACEAPEX_GPU_E_ARGS before the builder runs; known flags reach it unchanged; the builder's error
// becomes aceapex_gpu_last_error(); aceapex_gpu_version() == ACEAPEX_GPU_API_VERSION == major*10000+minor*100+patch.
// The flag masks are compared with the documented flags. Prints one claim line (head_gpu_abi).
// Build: g++ -std=c++17 -O2 -Isrc scripts/gpu_abi_test.cpp src/aceapex_gpu_abi.cpp
#include "aceapex_gpu.h"
#include <cstdio>
#include <type_traits>

static int calls = 0, stub_err = 0; static uint64_t seen = ~0ull; static char dummy;
aceapex_gpu_plan* agpu_plan_build(const void*, size_t, uint64_t flags, int* err) {
    calls++; seen = flags; *err = stub_err; return stub_err ? nullptr : (aceapex_gpu_plan*)&dummy; }

int main() {
    const char a[68] = {0}; int bad = 0, refused = 0;
    static_assert(std::is_same<decltype(&aceapex_gpu_plan_create), aceapex_gpu_plan* (*)(const void*, size_t, uint64_t)>::value, "plan_create signature");
    for (int b = 0; b < 64; b++) {
        const uint64_t f = 1ull << b; if (f & ACEAPEX_GPU_PLAN_FLAGS) continue;
        calls = 0; aceapex_gpu_plan* p = aceapex_gpu_plan_create(a, sizeof a, f);
        if (p || calls || aceapex_gpu_last_error() != ACEAPEX_GPU_E_ARGS) bad++; else refused++; }
    calls = 0; if (aceapex_gpu_plan_create(nullptr, 0, 0) || calls || aceapex_gpu_last_error() != ACEAPEX_GPU_E_ARGS) bad++;
    calls = 0; seen = ~0ull;
    if (aceapex_gpu_plan_create(a, sizeof a, ACEAPEX_GPU_PLAN_FLAGS) != (aceapex_gpu_plan*)&dummy || calls != 1 || seen != ACEAPEX_GPU_PLAN_FLAGS
        || aceapex_gpu_last_error() != ACEAPEX_GPU_OK) bad++;
    stub_err = ACEAPEX_GPU_E_ARCHIVE;
    if (aceapex_gpu_plan_create(a, sizeof a, 0) || aceapex_gpu_last_error() != ACEAPEX_GPU_E_ARCHIVE) bad++;
    stub_err = 0;
    const unsigned v = aceapex_gpu_version();
    const bool vok = v == ACEAPEX_GPU_API_VERSION
        && v == ACEAPEX_GPU_API_VERSION_MAJOR * 10000u + ACEAPEX_GPU_API_VERSION_MINOR * 100u + ACEAPEX_GPU_API_VERSION_PATCH;
    const bool mok = ACEAPEX_GPU_PLAN_FLAGS == ACEAPEX_GPU_VALIDATE_ZSTD && ACEAPEX_GPU_DECODE_FLAGS == ACEAPEX_GPU_VERIFY_XXH3;
    const bool ok = !bad && vok && mok && refused == 63;
    printf("head_gpu_abi\t%s\tplan_create(uint64_t flags): %d unknown flag bits refused with E_ARGS before the builder (%d wrong), known mask passed through, "
           "builder error reported; version %u.%u.%u = %u (aceapex_gpu_version %u)%s\n",
           ok ? "pass" : "fail", refused, bad, ACEAPEX_GPU_API_VERSION_MAJOR, ACEAPEX_GPU_API_VERSION_MINOR, ACEAPEX_GPU_API_VERSION_PATCH,
           ACEAPEX_GPU_API_VERSION, v, mok ? "" : "; flag masks differ from the documented flags");
    return ok ? 0 : 1;
}
