<!-- DRAFT PR text for inikep/lzbench, branch aceapex-2.2.0 (local, based on master ad5b458). NOT OPENED. -->

# aceapex: update to 2.2.0

Three commits on top of master (ad5b458, the lz+entropy/ + mk/ layout):

1. **aceapex: update to 2.2.0** - `lz+entropy/aceapex` sources from aceapex v2.2.0
   (https://github.com/yasha1971-coder/aceapex/releases/tag/v2.2.0), two new headers (`ax_rans.h`,
   `ax_lit_open.h`); `mk/aceapex.mk` needs no change (the one object #includes them). The wrapper decodes
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

## Suggestion, not part of this PR
FASTEST lists `aceapex,1`. With 2.2.0 the fastest level is `aceapex,3` (l1): on a 3 MB text sample
329 MB/s against 66 MB/s for level 1, with a smaller output (36.10 % against 38.40 %). If you agree,
`aceapex,3` could replace `aceapex,1` there; the aliases are left as they are.

## Tested
- lzbench CI set on this branch, x86-64 Linux (gcc 11.4): `-eLZ -v5 ./lzbench`, `-eLZ+ENTROPY -v5 ./lzbench`,
  `-eSYMMETRIC -v5 ./lzbench`, `-eFASTEST -t0,0 -T2 -jr .` - all pass. `-eaceapex,1,2,3` round-trips.
- aceapex sources on its own release gate (`scripts/cross_matrix.sh` in aceapex, libzstd 1.5.5 per target):
  x86-64, x86-32 (i686), ARM32 (armhf), ARM64 and PPC64LE under qemu-user - conformance set 44/44,
  byte-identical encoder output across all five, library round-trips 468/468, 4-thread concurrent test 0
  failures; MinGW x86-64: library builds (no Windows runner here).
- Not tested here: macOS, the Windows run itself, CUDA.
