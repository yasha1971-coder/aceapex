[written by ChatGPT (AI) at the author's request; checked by the author]

# CROWN-2 phase-build dependencies

This directory is a standalone research build. It neither includes the production
ACEAPEX CMake project nor changes any production codec or archive format.

| Dependency | Exact commit | License | Role |
|---|---|---|---|
| [libbsc](https://github.com/IlyaGrebnov/libbsc/tree/6542faafd0c235975e77e219c77f8227f770fe91) | `6542faafd0c235975e77e219c77f8227f770fe91` | Apache-2.0 | Unmodified BWT encode/decode reference, including its embedded libsais |
| [libsais 2.12.2](https://github.com/IlyaGrebnov/libsais/tree/b1aa1fde090e00a4e2030b9fb54198698b84e463) | `b1aa1fde090e00a4e2030b9fb54198698b84e463` | Apache-2.0 | Standalone single-thread forward construction for our implementation |

FetchContent downloads those exact commits. No libbsc implementation is copied
into our source: `baseline.cpp` calls declarations from the pinned public
`libbsc/bwt/bwt.h` and `libbsc/libbsc.h` headers. Dependency licenses remain in
their fetched source trees. No source patch, algorithm replacement, feature
macro renaming or new embedded dependency is applied to libbsc.

The build accepts CMake 3.22 on Ubuntu 22.04. The pinned libbsc upstream CMake
file requires 3.24, so our build lists the same twelve unchanged CPU sources
directly instead of editing that upstream file. OpenMP/CUDA sources and feature
definitions are absent. Standalone libsais uses its own upstream CMake target.

Build on the authorized C4 SPOT correctness/probe machine after the calibration
commit; do not treat cloud timings as ace-core performance:

```sh
cmake -S research/crown2-bwt -B /work/crown2-build \
  -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++
cmake --build /work/crown2-build --target crown2_probe -j 4
```

Both implementations and their dependency code use `Release`, `-O3`, `NDEBUG`
and `-march=x86-64-v3`; OpenMP, CUDA, `-march=native` and LTO are disabled. The
baseline calls use `LIBBSC_FEATURE_NONE`, with no multithreading or large pages.
Preserve the configure/build logs, compiler version, `compile_commands.json`,
source pins, binary hashes and all linked shared-library versions in evidence.

## Keep the two libsais implementations isolated

libbsc embeds a libsais implementation. Linking it into the same static symbol
namespace as standalone libsais can silently substitute one implementation for
the other. To prevent that, the unchanged libbsc static archive is linked only
inside `libcrown2_baseline.so`. Hidden visibility, `-Bsymbolic`, `--exclude-libs`
and an export map expose only our `baseline_encode`, `baseline_decode` and
`baseline_decode_inplace` wrappers. The own core links standalone libsais separately. This research probe
does not require a fully static executable; the historical static TurboBench
binary remains the independent full-codec known-answer control.

The cloud build must validate that `nm -D --defined-only libcrown2_baseline.so`
exports the three wrappers (and its version node), with no `libsais*` or `bsc_*`
API exports. Check `readelf -d crown2_probe`: its RPATH/RUNPATH must contain
`$ORIGIN`. Transfer `crown2_probe` and `libcrown2_baseline.so` together and verify
both SHA-256 values on ace-core before timings. Do not install or replace a
system library.

## Phase scope

`BaselineImage` contains BWT bytes, the primary index and the optional secondary
indexes returned directly by the public bsc API. It is not a bsc archive and
contains no entropy-coded payload. Both wrappers return explicit success/error.
The empty-input identity control bypasses the library and is never a timed BWT
data point.

The public inverse API is in-place. The convenience correctness wrapper
`baseline_decode(image, out, error)` copies the retained BWT into mutable `out`.
Do not time that preparation copy as part of the inverse phase: the actual codec
receives mutable QLFC output without such a copy.

For phase timing, allocate/fill `working = image.bwt` outside the timer and call
`baseline_decode_inplace(image, working, error)`. The function checks the working
length, copies the small secondary-index array, then calls `bsc_bwt_decode`.
All library inverse work and its workspace allocation/release stay inside the
timer. Give the own inverse the same preallocated output-buffer contract while
keeping its histogram/pointer workspace construction and allocation inside its
full-phase timer. Check input/output bytes outside both timers; never compare an
own traversal-only timer against the complete baseline phase. Library
initialization is performed once by preparation/correctness calls before warmed
measurements. Preserve these boundaries in the log.

The phase API by itself is not an integrity-protected archive decoder: malformed
metadata is rejected, but an arbitrary BWT-byte mutation can encode another
valid message. The research archive/probe must supply and verify its independent
checksum when implementing the corrupt-archive negative control.
