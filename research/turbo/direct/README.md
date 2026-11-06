# TURBO-3: direct comparison, single-threaded, pinned to CPU 2 (measurement only, nothing sent)

TurboBench v2026.11.05 release binary (`turbobench-linux-x86_64.tar.gz`, sha256 d5c2c2a1…dc06b); codecs in that build:
aceapex fast v2.6.1, zxc v0.15.0, Lz4 v1.11.0, misa77 v0.6.0. silesia.tar from corpus-collection (sha256 a667bac8…).
AMD EPYC 4344P (ace-core), `taskset -c 2`, load1 before: run 1 0.01, run 2 below 0.5; after: about 1.05.

Flags checked against `./turbobench` usage of this build: `-C3` exit on error, `-i5,5` 5 decompression / 5 compression
iterations, `-t2` at least 2 s per iteration, `-U` memory/stack usage, `-v0`. `-g` ("no merge w/ old result") writes no
.tbb at all in this build: run 1 used it (console only), run 2 is the same command without `-g` in a clean directory
(a new silesia.tar.tbb, no old result to merge).

| codec | ratio | C MB/s run 1 / 2 | D MB/s run 1 / 2 |
|---|---:|---:|---:|
| memcpy | 100.00 % | 15 984 / 16 044 | 16 469 / 18 080 |
| aceapex_fast 1 | 61.57 % | 1 115 / 1 106 | 12 304 / 12 934 |
| zxc 1 | 61.76 % | 1 043 / 1 047 | 10 674 / 10 663 |
| aceapex_fast 2 | 54.13 % | 25.3 / 25.5 | 10 658 / 10 683 |
| misa77 1 | 42.65 % | 151 / 152 | 9 663 / 9 671 |
| misa77 0 | 44.60 % | 412 / 414 | 9 033 / 9 534 |
| lz4 1 | 47.32 % | 944 / 944 | 6 459 / 6 447 |

Decompression, each row against the next slower row: aceapex_fast 1 vs zxc 1 +15.3 % (run 1), +21.3 % (run 2,
12 934 / 10 663). Run-to-run spread is visible in memcpy (16 469 vs 18 080, +9.8 %) and aceapex_fast 1 (+5.1 %), while
zxc 1 is stable (-0.1 %).
