<!-- DRAFT: internal multi-threading (-I#) of aceapex 2.2.0 in lzbench, and a comment for PR #336. NOT POSTED. -->

# aceapex 2.2.0, internal threads (-I#), silesia.tar

lzbench branch aceapex-2.2.0 (c5d959a, lzbench 2.4.1), AMD EPYC 4344P (8 cores / 16 threads), gcc 11.4,
bundled zstd 1.5.7, default iterations. As in lzbench's README: `-I#` pinned to cores 0 to #-1 with
`taskset` (`taskset -c 0-$((#-1)) ./lzbench -eaceapex,1,2,3/zstd,1,3 -I# silesia.tar`). -I16 uses the SMT
siblings of the 8 cores. zstd has no internal threads for decompression (its column stays flat).

Compression, MB/s:

| codec | ratio % | -I1 | -I8 | -I16 |
|---|---|---|---|---|
| aceapex 2.2.0 -1 | 32.56 | 86.1 | 386 | 370 |
| aceapex 2.2.0 -2 | 32.38 | 66.2 | 313 | 312 |
| aceapex 2.2.0 -3 | 31.44 | 195 | 623 | 640 |
| zstd 1.5.7 -1 | 34.53 / 34.58 | 690 | 4277 | 5365 |
| zstd 1.5.7 -3 | 31.20 / 31.24 | 411 | 2250 | 2465 |

Decompression, MB/s:

| codec | -I1 | -I8 | -I16 |
|---|---|---|---|
| aceapex 2.2.0 -1 | 1107 | 2926 | 3540 |
| aceapex 2.2.0 -2 | 1121 | 2954 | 3609 |
| aceapex 2.2.0 -3 | 1036 | 2271 | 2718 |
| zstd 1.5.7 -1 | 2153 | 2127 | 2095 |
| zstd 1.5.7 -3 | 1899 | 1892 | 1854 |

aceapex archives are the same bytes at every -I (the block layout does not depend on the thread count);
zstd's ratio moves slightly with -I (34.53 -> 34.58 %).

Note (found by this run): at threads=1 the aceapex 2.2.0 encoder still runs its entropy stage on helper
threads (three token streams at once, literal lanes up to the CPU count). Unpinned, `-eaceapex,3 -I1`
reports 304 MB/s at 146 % CPU; pinned to one core, 195 MB/s at 100 %. Decompression keeps to one thread
(102 %). The pinned numbers above are the single-core ones. The unpinned 1-thread compression figures in the
PR #336 description (level 1 96.1, level 2 71.6, level 3 305 MB/s) include those helper threads; pinned they
are 86.1 / 66.2 / 195. Fix planned for 2.2.1: the entropy stage keeps to the thread budget (archive bytes
unchanged - the literal lane count does not enter the format).

---

## Comment for PR #336 (draft)

Numbers for internal threads (`-I#`, pinned to cores 0..#-1 with taskset as in the README), silesia.tar,
EPYC 4344P 8C/16T, this branch:

| | -I1 comp / decomp | -I8 comp / decomp | -I16 comp / decomp |
|---|---|---|---|
| aceapex 2.2.0 -1 | 86 / 1107 | 386 / 2926 | 370 / 3540 |
| aceapex 2.2.0 -2 | 66 / 1121 | 313 / 2954 | 312 / 3609 |
| aceapex 2.2.0 -3 | 195 / 1036 | 623 / 2271 | 640 / 2718 |
| zstd 1.5.7 -1 | 690 / 2153 | 4277 / 2127 | 5365 / 2095 |
| zstd 1.5.7 -3 | 411 / 1899 | 2250 / 1892 | 2465 / 1854 |

aceapex uses -I for both directions (its blocks are independent, so decoding scales too: 3.2x at -I16),
and the output is identical at every thread count. Would you consider adding `aceapex,1,2,3` to INT_MT?
(Not done in this PR - aliases are yours.)

A correction to the description: the single-thread compression rows there were measured without pinning,
and the 2.2.0 encoder still runs its entropy stage on helper threads at threads=1, so they overstate one
core. Pinned to one core: level 1 86 MB/s (not 96), level 2 66 (not 72), level 3 195 (not 305).
Decompression is unaffected (one thread). I will make the entropy stage keep to the thread budget in 2.2.1;
the archive bytes do not change.
