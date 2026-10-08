# Secondary model A for the large-granule formats (from hprc4/results.json; model B failed on c0 < 0)

Model B: t(W) = c0 + (W + Q - 1) / D_Q with c0 = p50(W = 1) - Q / D_Q (independent probe). Model A: t(W) = (W + Q - 1) / D_Q,
no intercept. Errors = 100 x (p50 - predicted) / predicted at the verdict windows. Protocol v1.1: model A is informational and
never controls the verdict; model B FAILs when c0 < 0. All numbers from results.json (observations of each entry).

| format | variant | Q (B) | D_Q (GB/s) | c0 (us) | W | p50 (us) | model A (us) | err A | model B (us) | err B |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| zstd-seekable | seekable_compression level 3,  | 16,384 | 0.449 | -15.7 | 1024 | 21.03 | 38.81 | -45.8 % | 23.15 | -9.2 % |
| zstd-seekable | seekable_compression level 3,  | 16,384 | 0.449 | -15.7 | 8192 | 22.18 | 54.79 | -59.5 % | 39.13 | -43.3 % |
| zstd-seekable | seekable_compression level 3,  | 16,384 | 0.449 | -15.7 | 65536 | 99.07 | 182.62 | -45.8 % | 166.97 | -40.7 % |
| lz4-indexed | LZ4_compress_default, independ | 4,192,248 | 0.857 | -3234.5 | 1024 | 1658.79 | 4892.81 | -66.1 % | 1658.34 | +0.0 % |
| lz4-indexed | LZ4_compress_default, independ | 4,192,248 | 0.857 | -3234.5 | 8192 | 1686.51 | 4901.17 | -65.6 % | 1666.71 | +1.2 % |
| lz4-indexed | LZ4_compress_default, independ | 4,192,248 | 0.857 | -3234.5 | 65536 | 1692.83 | 4968.08 | -65.9 % | 1733.62 | -2.4 % |
| ozseg | l1_w64k | 65,536 | 0.428 | -26.0 | 1024 | 126.70 | 155.58 | -18.6 % | 129.57 | -2.2 % |
| ozseg | l1_w64k | 65,536 | 0.428 | -26.0 | 8192 | 135.84 | 172.33 | -21.2 % | 146.32 | -7.2 % |
| ozseg | l1_w64k | 65,536 | 0.428 | -26.0 | 65536 | 257.26 | 306.37 | -16.0 % | 280.36 | -8.2 % |
| ozseg | l1_w1m | 1,048,576 | 0.385 | -376.5 | 1024 | 2349.27 | 2726.73 | -13.8 % | 2350.26 | -0.0 % |
| ozseg | l1_w1m | 1,048,576 | 0.385 | -376.5 | 8192 | 2349.06 | 2745.35 | -14.4 % | 2368.89 | -0.8 % |
| ozseg | l1_w1m | 1,048,576 | 0.385 | -376.5 | 65536 | 2354.96 | 2894.33 | -18.6 % | 2517.86 | -6.5 % |
| ozseg | l3_w64k | 65,536 | 0.406 | -24.4 | 1024 | 138.58 | 164.06 | -15.5 % | 139.66 | -0.8 % |
| ozseg | l3_w64k | 65,536 | 0.406 | -24.4 | 8192 | 138.31 | 181.73 | -23.9 % | 157.33 | -12.1 % |
| ozseg | l3_w64k | 65,536 | 0.406 | -24.4 | 65536 | 277.80 | 323.07 | -14.0 % | 298.67 | -7.0 % |
| ozseg | l3_w1m | 1,048,576 | 0.386 | -386.4 | 1024 | 2330.25 | 2719.95 | -14.3 % | 2333.50 | -0.1 % |
| ozseg | l3_w1m | 1,048,576 | 0.386 | -386.4 | 8192 | 2331.17 | 2738.52 | -14.9 % | 2352.07 | -0.9 % |
| ozseg | l3_w1m | 1,048,576 | 0.386 | -386.4 | 65536 | 2376.01 | 2887.12 | -17.7 % | 2500.68 | -5.0 % |

What the table shows: for every large-granule format the W = 1 probe is faster than one granule at the sequential rate
(Q / D_Q), so c0 < 0 and model B is FAIL by the rule; the B predictions themselves stay within 2.4 % for LZ4 (4 MiB
blocks) and within 12 % for OZSEG, while model A (no intercept) overestimates by 14-66 % because the sequential D_Q of
these readers (adapter materialization of the full output inside the timed boundary) is lower than the per-granule
decode rate seen by a single window. For zstd seekable both models miss at 8 and 64 KiB (-43 / -41 % for B): the
window time grows much less than one 16 KiB frame per 16 KiB of W predicts. Applicability boundary for the paper:
model B holds (<= 20 %, c0 >= 0) for refrel3 and BGZF, whose granule is small against the window and whose D_Q is a
plain sequential decode; it is conservative (negative c0) for formats whose granule is >= the window or whose D_Q
includes materialization overhead - there the un-intercepted model A is an upper bound of the window time.

