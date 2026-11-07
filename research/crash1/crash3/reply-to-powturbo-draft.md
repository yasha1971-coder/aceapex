Draft v2 for TurboBench #65 (NOT sent; review by Claude, sending by Yakiv). Only the defect.

---

Thanks for the details. We found the cause, and it is in TurboBench's memory accounting rather than in aceapex.

In `turbobench.c`, the `aligned_alloc` wrapper calls itself instead of the saved libc pointer, so any `aligned_alloc`
call never returns. aceapex calls `aligned_alloc` on Linux only for decode buffers of 64 MiB and more, which is why
it shows up on large files, at decompression. The wrappers are compiled only without `STATIC=1` (`STATIC` sets
`NMEMSIZE`), so the release binaries are not affected. We reproduced it in a dynamic build (`make` without `STATIC=1`),
which is consistent with your description; could you confirm that your build was without `STATIC=1`?

The change we tested (tag v2026.11.06.165, 2cc8b4f; aceapex b67c858; ubuntu:26.10):

```diff
 void *aligned_alloc(size_t alignment, size_t size) {
-  if(!aligned_alloc) die("aligned_alloc");
-  void *p = (*aligned_alloc)(alignment, size);
+  if(!mem_aligned_alloc) mem_init();
+  if(!mem_aligned_alloc) die("aligned_alloc");
+  void *p = (*mem_aligned_alloc)(alignment, size);
   if(p) mem_add(malloc_usable_size(p));
   return p;
 }
```

GCC 16.2.0 build without the change, `turbobench silesia.tar -C4 -v2 -eaceapex,1` under gdb:

```
Program received signal SIGSEGV, Segmentation fault.
#0  aligned_alloc ()
#1  aligned_alloc ()
#2  aligned_alloc ()
#3  aligned_alloc ()
#4  aligned_alloc ()
```

With Clang 22.1.8 the same call does not crash but hangs (the recursion became a loop); stopped after 300 s:

```
#0  aligned_alloc ()
#1  ax_entropy_decode(...)
#2  ax_entropy_decode(...)
#3  aceapex_decompress_mt ()
#4  coddecomp ()
```

Same TurboBench SHA, your makefile (`make BLOSC=0 OPENZL=0 PIVCO=0 RUST=0`; with Clang 22 lzsa does not build and was
left out), silesia.tar and enwik9, aceapex 1-4 and
aceapex-fast 1/8, t1 and t4, `-C4` (24 runs per build):

| build | without the change | with the change |
|---|---|---|
| GCC 16.2.0 | aceapex 1-4: SIGSEGV 16/16; aceapex-fast 8/8 ok | 24/24 ok, no comparison errors |
| Clang 22.1.8 | aceapex 1 and 4: hang, 3/3 runs stopped after 300 s; aceapex-fast 1 ok | 24/24 ok, no comparison errors |

`make STATIC=1 PHAZ=0` without the change: 24/24 ok (the wrappers are not compiled).

Thanks!
