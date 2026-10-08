# H0 - size ledger of refrel3 v1 by stream, q4k and q16k, the 50 samples of the AGC comparison (read only)

Archives: the first 50 rows of the v1 cohort manifest (y1_HG00438.1 .. y1_HG02886.2, the set of research/agc_vs_refrel3),
`.wk/hprc_cohort/v1/<name>.{q4k,q16k}.rr3` as frozen (with block XXH3). Format and archives untouched: `ledger` decodes
with a copy of the frozen v1 decoder (5b6d5ce) plus cost hooks (ledger_patch.py: log2(4096/f) per symbol, raw bits to the
context of the preceding symbol). Method checked first on one clean-room fixture (asmC.q4k.hash: header + name + meta +
hashes + payload == 3 983 B). Run 2026-10-07 on ace-core, 69.7 s, peak RSS 6.1 GB (reference loaded once).
Build and run: `bash build.sh <dir> && <dir>/ledger ~/golden/genome/t2t.fa <archives...>`. Output ledger50.tsv
(SHA-256 in the commit message), summary.txt.

Sum checks: for every one of the 100 archives header + name + meta + block-hash section + payload == file size (100/100),
meta raw parts sum == meta_raw, payload fields + coder overhead == payload (fractional bytes, |diff| < 1 B total).

| stream | q4k bytes | q4k % | q16k bytes | q16k % |
|---|---:|---:|---:|---:|
| total (50 archives) | 1 110 996 471 | 100 | 730 769 451 | 100 |
| header 136 B + reference name | 7 200 | 0.001 | 7 200 | 0.001 |
| meta, zstd (raw: block table 82.6 MB / 22.1 MB, contig table 0.75 MB, model tables 0.11 MB, case runs 400 B) | 54 934 384 | 4.945 | 19 565 356 | 2.677 |
| block XXH3 section (8 B per block) | 294 248 760 | 26.485 | 73 562 360 | 10.066 |
| payload | 761 806 127 | 68.570 | 637 634 535 | 87.255 |
| - copy length (symbols + raw bits) | 340 245 270 | 30.626 | 303 173 790 | 41.487 |
| - ABS strand + 32-bit position | 79 235 138 | 7.132 | 73 233 095 | 10.021 |
| - coder overhead (3-byte state per block, rounding) | 91 066 701 | 8.197 | 23 063 052 | 3.156 |
| - DELTA (symbols + raw) | 63 409 265 | 5.708 | 55 143 096 | 7.546 |
| - literals (short + long runs) | 55 447 454 | 4.991 | 51 780 236 | 7.086 |
| - literal counts LL | 40 416 966 | 3.638 | 38 063 142 | 5.209 |
| - kind | 33 036 726 | 2.974 | 32 212 535 | 4.408 |
| - REP (which + delta) | 38 096 815 | 3.429 | 36 343 807 | 4.973 |
| - FLIP (which + delta) | 13 524 852 | 1.217 | 12 853 604 | 1.759 |
| - SELF distance | 7 327 940 | 0.660 | 11 768 177 | 1.610 |

Per-field symbol / raw split: summary.txt. Where the bytes go: in q4k the per-block fixed costs (block XXH3 26.5 %, rANS
flush 8.2 %, block table in the meta ~5 %) are ~40 % of the archive; in q16k ~16 %. In the payload, copy lengths are the
largest single field in both datasets (31 % / 41 %), ABS positions next (7 % / 10 %).
