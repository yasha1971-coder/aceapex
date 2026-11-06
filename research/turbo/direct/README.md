# TURBO-3/4: direct comparison, single-threaded, pinned to CPU 2 (measurement only, nothing sent)

TurboBench v2026.11.05 release binary (`turbobench-linux-x86_64.tar.gz`, sha256 d5c2c2a1…dc06b); codecs in that build:
aceapex fast v2.6.1, zxc v0.15.0, Lz4 v1.11.0, misa77 v0.6.0. silesia.tar from corpus-collection (sha256 a667bac8…).
AMD EPYC 4344P (ace-core), `taskset -c 2`, load1 before: run 1 0.01, run 2 < 0.5, run 3 0.03, run 4 0.42, run 5 0.44;
after: 0.98-1.05. Codec configuration single-threaded (no `t#`).

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

## Five runs (TURBO-4)

Runs 3-5: the run 2 command (no `-g`, clean directory, `taskset -c 2`, load1 < 0.5), each with its own .tbb, .md and
.log. Median and min-max over runs 1-5 (each run is the best of 5 iterations of at least 2 s):

| codec | ratio | compression MB/s, median [min-max] | decompression MB/s, median [min-max] |
|---|---:|---:|---:|
| memcpy | 100.00 % | 16 044 [15 973-17 156] | 16 668 [16 051-18 080] |
| aceapex_fast 1 | 61.57 % | 1 115 [1 083-1 126] | 12 922 [12 303-12 941] |
| zxc 1 | 61.76 % | 1 049 [1 043-1 059] | 10 674 [10 661-10 963] |
| misa77 1 | 42.65 % | 151 [151-154] | 9 655 [9 641-9 671] |
| lz4 1 | 47.32 % | 944 [944-945] | 6 447 [6 436-6 470] |

aceapex_fast 1 / zxc 1 by median: decompression 1.211x (12 922 / 10 674), compression 1.063x (1 115 / 1 049).
Per run, decompression: 1.153, 1.213, 1.179, 1.182, 1.154 (min 1.153, max 1.213). aceapex_fast 1 is bimodal:
12 303-12 304 MB/s in runs 1 and 5, 12 922-12 941 in runs 2-4; memcpy spreads 16 051-18 080 the same way.
Not in the table: aceapex_fast 2 10 683 [10 658-11 027] at 54.13 %, misa77 0 9 042 [9 033-9 542] at 44.60 %.
