<!-- DRAFT PR text for inikep/lzbench, branch aceapex-2.2.0 (local, based on master ad5b458). NOT OPENED. -->

# aceapex: update to 2.2.0

Three commits on top of master (ad5b458, the lz+entropy/ + mk/ layout):

1. **aceapex: update to 2.2.0** - `lz+entropy/aceapex` sources from aceapex v2.2.0
   (https://github.com/yasha1971-coder/aceapex/releases/tag/v2.2.0), two new headers (`ax_rans.h`,
   `ax_lit_open.h`), #included by the one object. `mk/aceapex.mk` gains `-I$(SRC)lz+entropy/zstd/lib`:
   the codec includes `<zstd.h>`, and without the bundled path a native build silently picked up the
   system header (a different zstd version from the one linked) while a cross build failed. The wrapper decodes
   with `aceapex_decompress_mt` (with `-T` each pool thread runs its codec copy with threads=1, which
   spawns nothing) and returns the decoded size.
2. **levels 1-3, README, CHANGELOG** - level 3 is the new l1 encoder on any input (levels 1 and 2 use it
   for DNA and keep the previous matcher for everything else); algorithm string unchanged
   ("LZ77 + FSE/Huffman": all three levels write zstd-coded streams under lzbench). The README note about
   the local double-free fix goes away: 2.2.0 allocates every stream with at least one byte, so lzbench
   carries no local change to the codec any more.
3. **remove unused acepx3.cpp and the aceapex3 / aceapex_stream wrappers** - never compiled or listed in
   the codec table.

`aceapex_cuda` (0.9) is not touched; its `aceapex_streams_t` has the same layout as the one the library
now declares. A separate PR will follow for it.

## A bug this fixes (not in the copy lzbench ships)
aceapex **2.1.0** kept per-call state (block size, decode error flag, DNA hint) in process globals.
Two calls at the same time - exactly what `lzbench -T` does - could return wrong output: with two threads
over lzbench's own source tree (4569 files) 2.1.0 returned wrong bytes for 22 files. The first 2.2.0
sync failed `-eFASTEST -t0,0 -T2 -jr .` the same way (2 decode errors), which is how it was found.
2.2.0 makes the state per call and adds a regression test (4 threads at once, full and region decode).
The copy currently in lzbench ("1.0.1") is **not** affected: 0 failures in the same test, 3 runs.

## Numbers
silesia.tar (211 938 580 B), AMD EPYC 4344P (8 cores / 16 threads), gcc 11.4, bundled zstd 1.5.7, default
lzbench iterations. "before" = upstream master ad5b458 (aceapex 1.0.1), "after" = this branch (c5d959a),
same machine, same file, runs back to back. With -T8 lzbench runs 8 codec copies at once, threads=1 each.

As lzbench reports it (no CPU pinning):

| codec | threads | compress MB/s | decompress MB/s | ratio % |
|---|---|---|---|---|
| aceapex 1.0.1 -1 (before) | 1 | 95.4 | 1454-1461 | 32.34 |
| aceapex 1.0.1 -2 (before) | 1 | 64.3 | 1464-1469 | 32.18 |
| aceapex 2.2.0 -1 | 1 | 95.4-96.1 | 1097-1105 | 32.56 |
| aceapex 2.2.0 -2 | 1 | 70.0-72.2 | 1113-1120 | 32.38 |
| aceapex 2.2.0 -3 | 1 | 305 | 1022 | 31.44 |
| zstd 1.5.7 -1 | 1 | 690 | 2138 | 34.53 |
| zstd 1.5.7 -3 | 1 | 413 | 1891 | 31.20 |
| aceapex 1.0.1 -1 (before) | 8 | 514-522 | 7632-7774 | 32.54 |
| aceapex 1.0.1 -2 (before) | 8 | 236-242 | 7594-7700 | 32.39 |
| aceapex 2.2.0 -1 | 8 | 488-493 | 7077-7188 | 32.73 |
| aceapex 2.2.0 -2 | 8 | 259-267 | 6847-7473 | 32.58 |
| aceapex 2.2.0 -3 | 8 | 1217 | 6586 | 31.52 |
| zstd 1.5.7 -1 | 8 | 4036 | 11466 | 34.54 |
| zstd 1.5.7 -3 | 8 | 2408 | 10389 | 31.21 |

**Why 1.0.1 looks faster at decode:** 1.0.1 decodes its literal stream with four threads of its own
(`lit_decompress`, NW=4, `pthread_create`) whatever the thread count it is given, so its "1 thread" row
used up to four cores (126 % CPU in a decode loop against 102 % for 2.2.0), and under -T8 its eight
copies spread over the SMT siblings. 2.2.0 keeps to the thread count it is given (threads=1 creates no
thread). With the CPUs fixed (`taskset`), same runs:

| codec | CPUs | decompress MB/s |
|---|---|---|
| aceapex 1.0.1 -1 / -2 (before) | 1 core (taskset -c 3) | 1017-1032 / 1029-1045 |
| aceapex 2.2.0 -1 / -2 | 1 core (taskset -c 3) | 1093-1098 / 1110-1115 (+7 %) |
| aceapex 1.0.1 -1 / -2, -T8 (before) | 8 logical CPUs (taskset -c 0-7) | 6821-7150 / 7058-7124 |
| aceapex 2.2.0 -1 / -2, -T8 | 8 logical CPUs (taskset -c 0-7) | 7410-7528 / 6622-7809 |

Levels 1-2 are 0.6-0.7 % larger than 1.0.1 on silesia (32.56 against 32.34 % at level 1): 2.2.0 flattens
match offsets to the first occurrence (shorter dependency chains for parallel/GPU match copy); with
AX_NOFLAT=1 the output is byte-identical to 1.0.1 in every stream (only the chunk-size field that 2.2.0
records in each token-stream header differs).
Level 3 is 2.9 % smaller than 1.0.1 -1. On one thread aceapex decodes at about half of zstd and encodes
slower than zstd -3 at every level; its point is independent blocks (region reads, GPU decode), not
beating zstd here.

## Suggestion, not part of this PR
FASTEST lists `aceapex,1`. With 2.2.0 the fastest level is `aceapex,3` (l1): on silesia.tar 305 MB/s
against 96 MB/s for level 1 on one thread, with a smaller output (31.44 % against 32.56 %). If you agree,
`aceapex,3` could replace `aceapex,1` there; the aliases are left as they are.

## Tested
- This branch, lzbench CI set, x86-64 Linux (gcc 11.4): `-eLZ -v5 ./lzbench`, `-eLZ+ENTROPY -v5 ./lzbench`,
  `-eSYMMETRIC -v5 ./lzbench`, `-eFASTEST -t0,0 -T2 -jr .` - all pass.
- This branch cross-built out of tree (`make -f .../Makefile CC=... CXX=...`) and run under qemu-user:
  ARM64 and PPC64LE (Bootlin glibc 2024.05 toolchains): `-eaceapex,1,2,3`, `-eLZ+ENTROPY -v5 ./lzbench`,
  `-eFASTEST -t0,0 -T2 -jr <tree>` - all pass. ARM32 (arm-linux-gnueabihf 11.4): `-eaceapex,1,2,3` and
  `-eLZ+ENTROPY` pass; `-eFASTEST -T2 -jr` passed aceapex and was killed later in lbzip2 (not aceapex;
  not investigated here).
- aceapex sources on its own release gate (`scripts/cross_matrix.sh` in aceapex, libzstd 1.5.5 per target):
  x86-64, x86-32 (i686), ARM32, ARM64 and PPC64LE under qemu-user - conformance set 44/44,
  byte-identical encoder output across all five, library round-trips 468/468, 4-thread concurrent test 0
  failures; MinGW x86-64: library builds (no Windows runner here).
- Not tested here: macOS, a Windows run, CUDA.
