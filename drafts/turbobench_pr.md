<!-- DRAFT PR text for powturbo/TurboBench, branch yasha1971-coder:aceapex (8024694). NOT OPENED. -->

# Add aceapex (v2.2.1)

[aceapex](https://github.com/yasha1971-coder/aceapex) is a parallel LZ77 codec with independent blocks
and match offsets resolved at encode time, so any block (or region) decodes on its own, on the CPU or
on a GPU. Release: [v2.2.1](https://github.com/yasha1971-coder/aceapex/releases/tag/v2.2.1);
DOI (all versions): [10.5281/zenodo.20440964](https://doi.org/10.5281/zenodo.20440964).

## What is added (4 places, following the misa77 / zxc entries)
1. **`.gitmodules` / submodule `aceapex`**, pinned to tag v2.2.1.
2. **`makefile`**: one block under `#--- A`, `ifneq ($(wildcard aceapex/.),)` with `-D_ACEAPEX`; the
   library is one translation unit (`aceapex/src/aceapex_api.cpp` includes the codec sources) built with
   `-Izstd/lib`. The only dependency is TurboBench's own zstd submodule; nothing external. xxHash is
   compiled inline (`-DXXH_INLINE_ALL`) so it does not clash with other codecs' copies.
3. **`plugin.cc`**: `P_ACEAPEX` in the enum, `#include "aceapex/src/aceapex.h"`, table row `"aceapex"`
   with levels `"1,2,3"`, and the C API in `codcomp` / `coddecomp` (`aceapex_compress`,
   `aceapex_decompress_mt`, threads=1), version via `ACEAPEX_VERSION_STRING`.
4. Nothing else changed.

Levels: 1 and 2 use aceapex's chain matcher on general data, 3 its fast "l1" encoder on any input
(1 and 2 switch to l1 by themselves on DNA).

## Checked
- `make` on Linux x86-64 (gcc 13.3), `./turbobench -l2` lists `aceapex v2.2.1`.
- Round-trip: `./turbobench -eaceapex,1,2,3/zstd,1,3 silesia.tar` and the same with `-C3` (exit on the
  first differing byte) on silesia.tar and on the turbobench binary: no error. The default codec set on
  the turbobench binary (`./turbobench turbobench -V0 -U`, as in build.yml) includes aceapex 1,2,3 and
  completes without error.
- aceapex itself is tested on x86-64, x86-32, ARM32, ARM64 and PPC64LE (the last three under qemu) and
  builds with MinGW; not built here on macOS or RISC-V.

## Note on the submodule pin
`submodule_update.yml` runs `git submodule update --remote` daily, which moves every submodule to the
head of its default branch; aceapex's `main` then replaces the v2.2.1 pin. If you prefer TurboBench to
follow releases only, a `branch =` line in `.gitmodules` pointing at a release branch would do it; tell me
and I will add one.
