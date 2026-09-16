# Components measured in the papers but not part of the default build

**rans1_v2.c** — order-1 rANS over literals, N=4 lines, 12-bit frequency
table, 64 KiB chunks. Measured at 2.1178 bits per byte against zstd-3's
2.861 on chr1 literals, encode 409 MB/s, decode 728 MB/s, round-trip exact.

Not in the default build. Decode falls 11% and region seek 43%, because the
four rANS lines share one byte stream with variable-length renormalisation:
reading a region means expanding the whole chunk, and checkpoints do not
help. Separate substreams per line would fix it, but that changes the
htscodecs schema this implementation deliberately follows. The figures are
correct; the trade is not.

**scan_bench.cu** — composition scan over the repeat-distance chain,
verified command by command against a CPU reference. The paper numbers on
an H100 and an RTX PRO 4000 come from this file.

Both are published here so the numbers in the papers have code behind them.
