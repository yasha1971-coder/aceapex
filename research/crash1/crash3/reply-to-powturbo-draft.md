Draft for TurboBench #65 (NOT sent; Yakiv sends)

---

Thanks for the details — that was enough to find it. The crash is in TurboBench's memory accounting, not in aceapex:
in `turbobench.c` the `aligned_alloc` interposer calls itself instead of the saved libc pointer, so every
`aligned_alloc` call recurses until the stack overflows:

```c
void *aligned_alloc(size_t alignment, size_t size) {
  if(!aligned_alloc) die("aligned_alloc");          // -> if(!mem_aligned_alloc)
  void *p = (*aligned_alloc)(alignment, size);      // -> (*mem_aligned_alloc)(alignment, size)
  ...
```

The interposers are compiled only without `STATIC=1` (`STATIC` sets `NMEMSIZE`), which is why the release binaries
work and a local `make` build crashes. aceapex calls `aligned_alloc` only for decode buffers of 64 MiB and more on Linux
(2 MiB aligned for transparent huge pages), hence "large files, at decompression"; aceapex_fast and lzbench do not
reach it. We reproduced it with a non-static GCC 16.2 build of v2026.11.06.164 on Ubuntu 26.10 (SIGSEGV, gdb shows
`aligned_alloc` calling itself), and the same interposer body crashes with GCC 11 at -O0/-O2/-O3; with
`mem_aligned_alloc` it works.

Two smaller things we noticed while testing:
- Windows: the aceapex block in the makefile is wrapped in `ifneq ($(OS), Windows)  # not compiling for windows in CI.`
  (lines 186/198 in v2026.11.06.165). Without that wrapper, v2026.11.06.165 builds with MSYS2 UCRT64 (`make STATIC=1
  PHAZ=0`) and aceapex 1-4 / aceapex-fast 1 pass `-C4` on silesia.tar.
- If it helps, the aceapex submodule can track our `release` branch (branch = release in .gitmodules), so TurboBench only
  picks up released versions; current master tracks main, which already contains unreleased level 15–18 changes labeled
  as 2.6.1.

Thanks!
