# CRASH-3 — TurboBench #65 "aceapex crashes at decompression on large files": cause found, not in aceapex

## Result

TurboBench's own memory accounting in `turbobench.c` (tag v2026.11.06.164, lines 314-319) interposes `aligned_alloc`
and calls itself instead of the libc function it saved:

    void *aligned_alloc(size_t alignment, size_t size) {
      if(!aligned_alloc) die("aligned_alloc");
      void *p = (*aligned_alloc)(alignment, size);    /* should be (*mem_aligned_alloc) */
      if(p) mem_add(malloc_usable_size(p));
      return p;
    }

Any `aligned_alloc` call in the process recurses until the stack overflows (SIGSEGV). The interposers are compiled only
in builds WITHOUT `STATIC=1`: the makefile sets `NMEMSIZE=1` / `-DNMEMSIZE` under `STATIC`, and `#if defined(NMEMSIZE)`
drops the block (`turbobench-v164-makefile-STATIC.txt`, `turbobench-v164-interposers.c.txt`). Release binaries are
built with `STATIC=1`, so they work; we reproduced the failure in a dynamic build (`make` without `STATIC=1`), which is
consistent with powturbo's description (his build command is not known).

aceapex calls `aligned_alloc` in one place: `ax_big_malloc` (src/aceapex_main.cpp), Linux only, for decode buffers of
64 MiB and more (2 MiB aligned for transparent huge pages). Hence "large files" and "at decompression"; aceapex_fast
(no aligned_alloc) and lzbench (no interposer) work.

## Evidence

- `ci-crash3-run3/` (run 42335668526): TurboBench v164 built with its unmodified makefile by GCC 16.2.0 in ubuntu:26.10
  (no STATIC): SIGSEGV 44/44 (silesia and enwik9, levels 1-4, t1/t2/t4, -f3), after the compression line, before the
  decompression line. The release binary (v2026.11.06.165, same aceapex b67c858 and zstd 49bf1d1; the v164 release was
  deleted upstream) on an EPYC 7763 without AVX-512: 52/52 pass.
- `ci-crash3b/` (run 42338579298): aceapex b67c858 + TurboBench's zstd with TurboBench's flags, the plugin's calls,
  no TurboBench: g++-16 and clang++-22, 8 variants each (-O3, -O3 -g, -O2, -fno-strict-aliasing, -mavx2, no -march,
  UBSan, ASan+UBSan): 16/16 pass. The library alone does not crash.
- `ci-crash3c/` (run 42340667101): the GCC 16 TurboBench binary under gdb: `SIGSEGV in aligned_alloc ()`, 30 frames of
  `aligned_alloc+18`, `aligned_alloc+13: call aligned_alloc`, rsp at a page boundary (stack overflow). The link map puts
  `malloc`, `calloc`, `memalign`, `posix_memalign`, `aligned_alloc`, `realloc`, `free` in `build-gcc16/turbobench.o`
  (`link-map-allocators.txt`). zstd is not involved: aceapex's ZSTD_* come from build-gcc16/zstd/libzstd.a
  (`relink.txt`); aocl's copy is prefixed `AOCLLZB_ZSTD_*` (`map-zstd.txt`).
- `mini/` (ace-core, gcc 11.4): `interp_tb.c` = that interposer body + one 256 MiB aligned_alloc: SIGSEGV at -O0, -O2,
  -O3; `fixed_tb.c` (`mem_aligned_alloc`): rc 0. Compiler-independent.

Reproduction and cause, separately: the preregistered prediction H1 (a GCC 16 build reproduces the crash) held; the causal
hypothesis behind it (toolchain / AVX-512) was wrong; the factor is the enabled memory interposer (a build without
`STATIC=1`). Clang "22.1.18" from the report is an unconfirmed version: 22.1.8 is the last release of LLVM 22.1.x
(a typo is likely); 22.1.8 was used.

## Fix (TurboBench; not ours): the pointer check and the call

    (tb-fix.patch)
    -  if(!aligned_alloc) die("aligned_alloc");
    -  void *p = (*aligned_alloc)(alignment, size);
    +  if(!mem_aligned_alloc) mem_init();
    +  if(!mem_aligned_alloc) die("aligned_alloc");
    +  void *p = (*mem_aligned_alloc)(alignment, size);

No change in aceapex, API/ABI or release is needed for this crash. The deciding run on the full TurboBench (A-F,
`tb-fix.patch`) is CRASH-3d.

## CRASH-3d — the deciding run on the full TurboBench (one SHA for every row)

TurboBench tag v2026.11.06.165 = 2cc8b4f, aceapex b67c858, zstd 49bf1d1, ubuntu:26.10 (pinned digest); GCC 16.2.0
(Ubuntu 16.2.0-3ubuntu1), Clang 22.1.8 (Ubuntu 1:22.1.8-1ubuntu1). Their makefile: `make CC=… CXX=… CG=clang-22
BUILD=… BLOSC=0 OPENZL=0 PIVCO=0 RUST=0` (Clang 22 does not build lzsa: left out). silesia.tar and enwik9, aceapex 1-4
and aceapex-fast 1/8, t1 and t4, `-C4 -v2 -U`, each run its own process (24 per build). Runs: 42358… A, B, D, E
(8474b89), F (e42b724), C-bt (4820dce). `ci-crash3d/<row>/`, `ci-crash3d-bt/`.

| row | build | result | silesia t1 decompression MB/s, aceapex 1 / aceapex-fast 1 | CPU of the runner |
|---|---|---|---|---|
| A | GCC 16.2, their make, no patch | aceapex 1-4 SIGSEGV 16/16 (gdb: `aligned_alloc` recursing); aceapex-fast 8/8 ok | - / 8 624 | EPYC 7763 |
| B | GCC 16.2, their make, `tb-fix.patch` | 24/24 ok, -C4 clean | 950 / 9 158 | EPYC 7763 |
| C | Clang 22.1.8, their make, no patch | aceapex 1 silesia, aceapex 1 enwik9, aceapex 4 silesia: hang, stopped by SIGINT at 300 s, bt `#0 aligned_alloc` (one frame: a loop) <- `ax_entropy_decode` <- `aceapex_decompress_mt` <- `coddecomp`; aceapex-fast 1 ok in 7 s (C-bt; the full C row hung > 4 h and was cancelled) | - / 15 674 | EPYC 9V45 |
| D | Clang 22.1.8, their make, `tb-fix.patch` | 24/24 ok, -C4 clean | 807 / 5 877 | Xeon 8573C |
| E | GCC 16.2, no patch, aceapex with `-DACEAPEX_ENV_TUNING`, run with `AX_HUGE=0` | 24/24 ok (aligned_alloc not called) | 802 / 9 085 | EPYC 7763 |
| F | GCC 16.2, `make STATIC=1 PHAZ=0` (linked with g++-16/gcc-16), no patch | 24/24 ok (no wrappers: `-DNMEMSIZE`) | 1 006 / 6 837 | Xeon 6973P |

Speeds come from different runner CPUs and are not comparable across rows. Ratio in every row that ran: aceapex 1
32.56 % (silesia), aceapex-fast 1 61.57 %, aceapex-fast 8 39.21 %.

Kill criterion (B or D fails) not met: B and D 0 failures. TurboBench's memory counter works in B/D (it is compiled out
in the STATIC release builds): aceapex 1 silesia C MEM 1.87 GB / D MEM 108 MB, enwik9 D MEM 581 MB (its C MEM prints
negative, -952 466 152: apparently a 32-bit counter overflow in TurboBench's output); aceapex-fast 1 C 2.2 MB / D 1.8 KB.

`mem_init` sets `mem_aligned_alloc` through `dlsym(RTLD_NEXT, "aligned_alloc")` under `__STDC_VERSION__ >= 201112L`;
turbobench.c is compiled as C (`gcc-16 -O2 ... turbobench.c`, default gnu17), so the condition holds.
