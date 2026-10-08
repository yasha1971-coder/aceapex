# RESULTS_M6 - AGC 3.2.4 against the cohort size N, refrel3 v1 on the same N; counters for H1-H5

Protocol: PROTOCOL_M6 v1.1, SHA-256 ec0ce9f9d92fdc7eb448d72ba10932a8a5660f15d47038f5f6a6ada6522f0815 (frozen before the
runs, commit 0760d32); method check on N = 5 PASS (logs/N5). Main run `run_all.sh` 2026-10-07 10:32 - 19:27 UTC, ace-core
(AMD EPYC 4344P 8c/16t, 125 GB, Ubuntu 22.04.5, kernel 5.15.0-163), g++ 11.4.0, AGC 3.2.4 e67e3fc (M1 build, -O3
-march=native), refrel3 v1 @ 5b6d5ce, aceapex 0760d32 at the start; silence gate before every timing and perf series
(load < 0.5; logs/N*/silence_*.txt). Nothing of ours ran during the timed rows; the H4 estimate and the hw-apex native
builds ran only in the request / integrity phases (gate held). Hypotheses: G1 (HW, source-only map of AGC e67e3fc,
H1-H5); a "G1b" package was not found on ace-core - G1 is the one used.

## Archives (one `agc create -d -k 31 -l 20 -s 60000 -b 50 -t 16` per N through FIFOs from the q16k v1 archives; N = 558 = agc558.agc of M1)

| N | archive bytes | SHA-256 | create wall | create peak RSS | integrity |
|---:|---:|---|---:|---:|---|
| 50 | 1 139 665 993 | bde301b1... | 6:49 | 26.5 GB | listset t2t + 50, listctg 50/50 |
| 100 | 1 482 895 757 | fd4340a0... | 12:53 | 26.4 GB | listset t2t + 100, listctg 100/100 |
| 200 | 1 990 727 652 | 3a5a9237... | 26:47 | 27.5 GB | listset t2t + 200, listctg 200/200 |
| 558 | 3 721 635 360 | 9011701c... | 1:17:21 (M1) | 34.7 GB (M1) | listset t2t + 558, listctg 558/558 |

Minus T2T alone (707 323 301 B): 8.65 / 7.76 / 6.42 / 5.40 MB per assembly at N = 50 / 100 / 200 / 558. refrel3 on the
same N: the q4k / q16k v1 archives of the manifest (with block XXH3).

Requests per N (logs/N*/inputs.sha256): 10 000 windows of 4 096 (`random.Random(20261011 + N)`), 100 regions of 1 Mb
(`20261111 + N`), whole samples = the first 4 manifest assemblies; truth `truth_v1` (every v1 archive decoded with every
check). H5 at every N (logs/N*/h5_gdb.txt): agc_get_ctg_seq -> CAGCFile::GetCtgSeq -> GetContigString ->
decompress_contig, `fast = false`; counters `dc_fast_false` == `dc_calls` for every counted request.

## Timing (median of 9 timed runs after 3 warm-ups; every answer of every run SHA-256 == truth)

### windows W = 4 096 (10 000) - requests/s

| N | AGC t1 | AGC t16 | refrel3 q4k t1 | refrel3 q4k t16 | refrel3 q16k t1 | refrel3 q16k t16 |
|---:|---:|---:|---:|---:|---:|---:|
| 50 | 868 | 3 331 | 200 884 | 1 676 165 | 93 442 | 863 111 |
| 100 | 38 | 139 | 178 591 | 1 529 052 | 87 472 | 813 273 |
| 200 | 28 | 109 | 186 487 | 1 488 538 | 86 522 | 827 746 |
| 558 | 26 | 97 | 145 222 | 1 306 848 | 73 690 | 717 772 |

### regions 1 Mb (100) - requests/s

| N | AGC t1 | AGC t16 | refrel3 q4k t1 | refrel3 q4k t16 | refrel3 q16k t1 | refrel3 q16k t16 |
|---:|---:|---:|---:|---:|---:|---:|
| 50 | 294 | 988 | 1 907 | 8 137 | 1 911 | 6 538 |
| 100 | 43 | 145 | 1 925 | 7 024 | 1 921 | 7 007 |
| 200 | 26 | 95 | 2 167 | 8 827 | 2 308 | 9 083 |
| 558 | 26 | 92 | 2 459 | 9 298 | 2 485 | 9 680 |

### whole samples (first 4) - s per sample

| N | AGC t1 | AGC t16 | refrel3 q4k t1 | refrel3 q4k t16 | refrel3 q16k t1 | refrel3 q16k t16 |
|---:|---:|---:|---:|---:|---:|---:|
| 50 | 7.648 | 2.781 | 1.292 | 0.234 | 1.279 | 0.232 |
| 100 | 7.732 | 2.772 | 1.306 | 0.233 | 1.277 | 0.232 |
| 200 | 7.509 | 2.794 | 1.288 | 0.233 | 1.267 | 0.232 |
| 558 | 7.608 | 2.773 | 1.301 | 0.233 | 1.271 | 0.232 |

### Median seconds per row (min .. max), peak RSS GB

| N | row | median s | min | max | RSS GB | open s |
|---:|---|---:|---:|---:|---:|---:|
| 50 | rr3_q4k_win_t1 | 0.0498 | 0.0486 | 0.0519 | 6.14 | 15.7 |
| 50 | rr3_q4k_reg_t1 | 0.0524 | 0.0516 | 0.0538 | 6.14 | 15.8 |
| 50 | rr3_q4k_s4_t1 | 5.1663 | 5.1626 | 5.1718 | 19.70 | 15.8 |
| 50 | rr3_q16k_win_t1 | 0.1070 | 0.1062 | 0.1112 | 6.14 | 15.2 |
| 50 | rr3_q16k_reg_t1 | 0.0523 | 0.0515 | 0.0553 | 6.14 | 15.2 |
| 50 | rr3_q16k_s4_t1 | 5.1164 | 5.1145 | 5.1181 | 18.68 | 15.2 |
| 50 | agc_win_t1 | 11.5210 | 11.4501 | 11.5582 | 1.30 | 0.4 |
| 50 | agc_reg_t1 | 0.3402 | 0.3350 | 0.3407 | 1.35 | 0.4 |
| 50 | agc_s4_t1 | 30.5926 | 30.4541 | 31.1323 | 15.94 | 0.4 |
| 50 | rr3_q4k_win_t16 | 0.0060 | 0.0059 | 0.0061 | 6.14 | 15.8 |
| 50 | rr3_q4k_reg_t16 | 0.0123 | 0.0118 | 0.0157 | 6.14 | 15.7 |
| 50 | rr3_q4k_s4_t16 | 0.9366 | 0.9334 | 0.9471 | 19.71 | 15.8 |
| 50 | rr3_q16k_win_t16 | 0.0116 | 0.0115 | 0.0124 | 6.14 | 15.3 |
| 50 | rr3_q16k_reg_t16 | 0.0153 | 0.0117 | 0.0167 | 6.14 | 15.3 |
| 50 | rr3_q16k_s4_t16 | 0.9290 | 0.9285 | 0.9325 | 18.68 | 15.3 |
| 50 | agc_win_t16 | 3.0018 | 2.9277 | 3.0457 | 19.97 | 5.9 |
| 50 | agc_reg_t16 | 0.1012 | 0.0796 | 0.1137 | 19.39 | 6.0 |
| 50 | agc_s4_t16 | 11.1240 | 11.0589 | 11.2386 | 33.96 | 5.9 |
| 100 | rr3_q4k_win_t1 | 0.0560 | 0.0551 | 0.0565 | 7.07 | 16.9 |
| 100 | rr3_q4k_reg_t1 | 0.0519 | 0.0514 | 0.0545 | 7.13 | 16.9 |
| 100 | rr3_q4k_s4_t1 | 5.2253 | 5.2210 | 5.2280 | 21.71 | 16.9 |
| 100 | rr3_q16k_win_t1 | 0.1143 | 0.1133 | 0.1166 | 6.15 | 15.8 |
| 100 | rr3_q16k_reg_t1 | 0.0520 | 0.0505 | 0.0538 | 6.15 | 15.7 |
| 100 | rr3_q16k_s4_t1 | 5.1098 | 5.1086 | 5.1134 | 19.66 | 15.7 |
| 100 | agc_win_t1 | 263.5111 | 262.6952 | 264.6341 | 1.64 | 0.5 |
| 100 | agc_reg_t1 | 2.3225 | 2.2978 | 2.6548 | 1.71 | 0.5 |
| 100 | agc_s4_t1 | 30.9286 | 30.8698 | 30.9615 | 16.28 | 0.5 |
| 100 | rr3_q4k_win_t16 | 0.0065 | 0.0065 | 0.0068 | 7.07 | 17.0 |
| 100 | rr3_q4k_reg_t16 | 0.0142 | 0.0110 | 0.0143 | 7.13 | 16.9 |
| 100 | rr3_q4k_s4_t16 | 0.9339 | 0.9336 | 0.9350 | 21.71 | 16.9 |
| 100 | rr3_q16k_win_t16 | 0.0123 | 0.0122 | 0.0124 | 6.15 | 15.7 |
| 100 | rr3_q16k_reg_t16 | 0.0143 | 0.0112 | 0.0146 | 6.15 | 15.7 |
| 100 | rr3_q16k_s4_t16 | 0.9295 | 0.9290 | 0.9306 | 19.67 | 15.6 |
| 100 | agc_win_t16 | 71.7890 | 70.1903 | 74.0031 | 25.38 | 7.6 |
| 100 | agc_reg_t16 | 0.6893 | 0.6150 | 0.7470 | 24.92 | 7.5 |
| 100 | agc_s4_t16 | 11.0879 | 11.0017 | 11.2251 | 39.36 | 7.5 |
| 200 | rr3_q4k_win_t1 | 0.0536 | 0.0527 | 0.0621 | 10.95 | 18.8 |
| 200 | rr3_q4k_reg_t1 | 0.0461 | 0.0453 | 0.0474 | 11.00 | 18.9 |
| 200 | rr3_q4k_s4_t1 | 5.1523 | 5.1497 | 5.1588 | 25.59 | 18.9 |
| 200 | rr3_q16k_win_t1 | 0.1156 | 0.1143 | 0.1172 | 6.89 | 16.6 |
| 200 | rr3_q16k_reg_t1 | 0.0433 | 0.0426 | 0.0460 | 6.95 | 16.6 |
| 200 | rr3_q16k_s4_t1 | 5.0700 | 5.0659 | 5.0710 | 21.53 | 16.6 |
| 200 | agc_win_t1 | 357.4321 | 346.8786 | 358.7829 | 2.14 | 0.7 |
| 200 | agc_reg_t1 | 3.7813 | 3.7742 | 3.7978 | 2.21 | 0.7 |
| 200 | agc_s4_t1 | 30.0363 | 30.0117 | 30.0551 | 16.78 | 0.7 |
| 200 | rr3_q4k_win_t16 | 0.0067 | 0.0067 | 0.0069 | 10.95 | 18.9 |
| 200 | rr3_q4k_reg_t16 | 0.0113 | 0.0112 | 0.0121 | 11.01 | 18.8 |
| 200 | rr3_q4k_s4_t16 | 0.9319 | 0.9316 | 0.9331 | 25.59 | 18.8 |
| 200 | rr3_q16k_win_t16 | 0.0121 | 0.0119 | 0.0122 | 6.89 | 16.8 |
| 200 | rr3_q16k_reg_t16 | 0.0110 | 0.0109 | 0.0123 | 6.96 | 16.6 |
| 200 | rr3_q16k_s4_t16 | 0.9286 | 0.9283 | 0.9301 | 21.53 | 16.7 |
| 200 | agc_win_t16 | 91.7407 | 91.2486 | 94.0789 | 33.39 | 10.0 |
| 200 | agc_reg_t16 | 1.0485 | 0.9964 | 1.0985 | 32.97 | 10.0 |
| 200 | agc_s4_t16 | 11.1743 | 11.0551 | 11.2411 | 47.34 | 9.9 |
| 558 | rr3_q4k_win_t1 | 0.0689 | 0.0668 | 0.0702 | 24.93 | 25.8 |
| 558 | rr3_q4k_reg_t1 | 0.0407 | 0.0403 | 0.0413 | 25.00 | 25.9 |
| 558 | rr3_q4k_s4_t1 | 5.2049 | 5.2025 | 5.2084 | 39.59 | 25.8 |
| 558 | rr3_q16k_win_t1 | 0.1357 | 0.1326 | 0.1434 | 13.59 | 19.6 |
| 558 | rr3_q16k_reg_t1 | 0.0402 | 0.0368 | 0.0410 | 13.67 | 19.6 |
| 558 | rr3_q16k_s4_t1 | 5.0836 | 5.0815 | 5.0849 | 28.25 | 19.6 |
| 558 | agc_win_t1 | 377.7924 | 376.3986 | 378.6810 | 3.84 | 1.3 |
| 558 | agc_reg_t1 | 3.7802 | 3.7694 | 3.8364 | 3.92 | 1.3 |
| 558 | agc_s4_t1 | 30.4335 | 30.3973 | 30.4719 | 18.47 | 1.3 |
| 558 | rr3_q4k_win_t16 | 0.0077 | 0.0076 | 0.0079 | 24.94 | 25.8 |
| 558 | rr3_q4k_reg_t16 | 0.0108 | 0.0100 | 0.0109 | 25.00 | 25.8 |
| 558 | rr3_q4k_s4_t16 | 0.9309 | 0.9300 | 0.9313 | 39.59 | 25.9 |
| 558 | rr3_q16k_win_t16 | 0.0139 | 0.0139 | 0.0140 | 13.59 | 19.6 |
| 558 | rr3_q16k_reg_t16 | 0.0103 | 0.0099 | 0.0106 | 13.67 | 19.7 |
| 558 | rr3_q16k_s4_t16 | 0.9286 | 0.9281 | 0.9291 | 28.25 | 19.6 |
| 558 | agc_win_t16 | 102.8170 | 102.6044 | 103.2283 | 60.62 | 18.8 |
| 558 | agc_reg_t16 | 1.0898 | 1.0526 | 1.1383 | 60.11 | 19.1 |
| 558 | agc_s4_t16 | 11.0933 | 10.9573 | 11.2099 | 74.83 | 19.0 |

## Counters (counting build, one handle, one thread; medians per request)

### first 1 000 windows, file order

| counter | N=50 | N=100 | N=200 | N=558 |
|---|---:|---:|---:|---:|
| zstd_calls | 2 | 8 | 8 | 8 |
| zstd_in | 17 424 | 3 844 146 | 3 751 374 | 3 766 628 |
| zstd_out | 15 009 | 15 739 885 | 15 445 218 | 15 627 928 |
| dctx_create | 1 | 1 | 1 | 1 |
| alloc_new_calls | 64 | 68 065 | 19 212 | 16 946 |
| alloc_new_bytes | 466 322 | 108 102 682 | 104 232 804 | 105 407 960 |
| desc_batch_names_load | 0 | 1 | 1 | 1 |
| desc_batch_details_load | 0 | 1 | 1 | 1 |
| batch_clear | 0 | 1 | 1 | 1 |
| desc_contigs_scanned | 36 | 38 | 17 | 12 |
| desc_segments_copied | 734 | 673 | 1 453 | 2 146 |
| dc_desc_scanned | 294 | 256 | 525 | 824 |
| dc_seg_decoded | 1 | 1 | 1 | 1 |
| lz_ref_bytes | 60 031 | 60 031 | 60 031 | 60 031 |
| lz_delta_bytes | 562 | 566 | 576 | 560 |
| dc_assembled_bytes | 60 039 | 60 038 | 60 038 | 60 040 |
| conv_bytes | 4 096 | 4 096 | 4 096 | 4 096 |

### the same 1 000 windows sorted by (manifest order, contig, start)

| counter | N=50 | N=100 | N=200 | N=558 |
|---|---:|---:|---:|---:|
| zstd_calls | 2 | 2 | 2 | 2 |
| zstd_in | 17 360 | 17 514 | 17 512 | 17 416 |
| zstd_out | 15 009 | 15 009 | 15 009 | 15 009 |
| dctx_create | 1 | 1 | 1 | 1 |
| alloc_new_calls | 63 | 67 | 47 | 42 |
| alloc_new_bytes | 462 824 | 464 407 | 508 826 | 536 268 |
| desc_batch_names_load | 0 | 0 | 0 | 0 |
| desc_batch_details_load | 0 | 0 | 0 | 0 |
| batch_clear | 0 | 0 | 0 | 0 |
| desc_contigs_scanned | 36 | 38 | 17 | 12 |
| desc_segments_copied | 734 | 673 | 1 453 | 2 146 |
| dc_desc_scanned | 294 | 256 | 525 | 824 |
| dc_seg_decoded | 1 | 1 | 1 | 1 |
| lz_ref_bytes | 60 031 | 60 031 | 60 031 | 60 031 |
| lz_delta_bytes | 562 | 566 | 576 | 560 |
| dc_assembled_bytes | 60 039 | 60 038 | 60 038 | 60 040 |
| conv_bytes | 4 096 | 4 096 | 4 096 | 4 096 |

### 100 regions of 1 Mb

| counter | N=50 | N=100 | N=200 | N=558 |
|---|---:|---:|---:|---:|
| zstd_calls | 36 | 38 | 42 | 42 |
| zstd_in | 308 164 | 538 774 | 4 041 514 | 4 048 085 |
| zstd_out | 270 179 | 422 690 | 15 700 400 | 15 840 723 |
| dctx_create | 1 | 1 | 1 | 1 |
| alloc_new_calls | 315 | 613 | 19 464 | 17 172 |
| alloc_new_bytes | 8 233 852 | 20 560 074 | 112 155 750 | 112 813 934 |
| desc_batch_names_load | 0 | 0 | 1 | 1 |
| desc_batch_details_load | 0 | 0 | 1 | 1 |
| batch_clear | 0 | 0 | 1 | 1 |
| desc_contigs_scanned | 36 | 35 | 13 | 12 |
| desc_segments_copied | 840 | 637 | 1 447 | 2 230 |
| dc_desc_scanned | 343 | 343 | 454 | 938 |
| dc_seg_decoded | 18 | 18 | 18 | 18 |
| lz_ref_bytes | 1 080 582 | 1 080 584 | 1 080 586 | 1 080 594 |
| lz_delta_bytes | 10 153 | 10 023 | 9 826 | 9 980 |
| dc_assembled_bytes | 1 079 510 | 1 079 056 | 1 079 619 | 1 079 679 |
| conv_bytes | 1 000 000 | 1 000 000 | 1 000 000 | 1 000 000 |

### zstd call sites (windows, file order): calls and bytes per request

| site | N=50 calls / in B / out B | N=100 calls / in B / out B | N=200 calls / in B / out B | N=558 calls / in B / out B |
|---|---|---|---|---|
| createDCtx@agc_decompressor_lib.cpp:184 | 1.00 / 0 / 0 | 1.00 / 0 / 0 | 1.00 / 0 / 0 | 1.00 / 0 / 0 |
| createDCtx@collection_v3.cpp:148 | 0.01 / 0 / 0 | 0.01 / 0 / 0 | 0.01 / 0 / 0 | 0.01 / 0 / 0 |
| decompressDCtx@collection_v3.cpp:151 | 0.22 / 76 418 / 304 464 | 3.09 / 1 985 443 / 7 965 249 | 4.36 / 2 753 781 / 11 240 093 | 5.53 / 3 429 790 / 14 144 777 |
| decompressDCtx@segment.cpp:164 | 0.00 / 244 / 0 | 0.01 / 403 / 0 | 0.00 / 94 / 0 | 0.00 / 166 / 0 |
| decompressDCtx@segment.cpp:263 | 0.02 / 54 / 1 321 | 0.01 / 93 / 2 707 | 0.02 / 117 / 3 739 | 0.02 / 137 / 2 783 |
| decompressDCtx@segment.cpp:269 | 1.04 / 15 156 / 16 626 | 1.05 / 15 558 / 16 931 | 1.05 / 15 337 / 16 849 | 1.05 / 15 588 / 17 406 |
| decompressDCtx@segment.cpp:306 | 1.05 / 4 133 / 0 | 1.05 / 5 193 / 0 | 1.06 / 5 455 / 0 | 1.07 / 5 834 / 0 |
| freeDCtx@agc_decompressor_lib.cpp:290 | 1.00 / 0 / 0 | 1.00 / 0 / 0 | 1.00 / 0 / 0 | 1.00 / 0 / 0 |

## Profile (perf, cycles:u, one thread, 10 000 windows; samples under agc_get_ctg_seq)

### N = 50: profiled pass 11.6 s for 10 000 windows; share of samples: 77.34%  agc_get_ctg_seq;     22.66%  [other]

top 20 by self time:

| % | symbol |
|---:|---|
| 55.53 | `CCollection_V3::deserialize_contig_details                                                ` |
| 4.96 | `std::vector<segment_desc_t, std::allocator<segment_desc_t> >::_M_default_append           ` |
| 3.47 | `__memset_avx512_unaligned_erms                                                            ` |
| 2.63 | `__memmove_avx512_unaligned_erms                                                           ` |
| 2.09 | `CSegment::tuples2bytes                                                                    ` |
| 0.75 | `CSegment::get                                                                             ` |
| 0.65 | `CCollection_V3::decode_split                                                              ` |
| 0.57 | `std::vector<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> ` |
| 0.37 | `CAGCDecompressorLibrary::GetContigString                                                  ` |
| 0.35 | `CLZDiff_V2::Decode                                                                        ` |
| 0.20 | `cfree@GLIBC_2.2.5                                                                         ` |
| 0.19 | `operator delete                                                                           ` |
| 0.17 | `CCollection_V3::split_string                                                              ` |
| 0.16 | `CCollection_V3::deserialize_contig_names                                                  ` |
| 0.15 | `__memcmp_evex_movbe                                                                       ` |
| 0.12 | `std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >::_M_replac` |
| 0.10 | `std::vector<segment_desc_t, std::allocator<segment_desc_t> >::operator=                   ` |
| 0.08 | `CLZDiff_V2::decode_match                                                                  ` |
| 0.08 | `std::vector<CCollection_V3::contig_desc_t, std::allocator<CCollection_V3::contig_desc_t> >` |
| 0.06 | `CAGCBasic::reverse_complement                                                             ` |

top 20 by children time:

| % | symbol |
|---:|---|
| 77.34 | `std::thread::_State_impl<std::thread::_Invoker<std::tuple<par_for<main::{lambda()#1}::oper` |
| 77.34 | `agc_get_ctg_seq                                                                           ` |
| 77.33 | `CAGCDecompressorLibrary::GetContigString                                                  ` |
| 72.21 | `CCollection_V3::get_contig_desc                                                           ` |
| 68.74 | `CCollection_V3::load_batch_contig_details                                                 ` |
| 66.33 | `CCollection_V3::deserialize_contig_details                                                ` |
| 7.23 | `__memset_avx512_unaligned_erms                                                            ` |
| 5.18 | `std::vector<segment_desc_t, std::allocator<segment_desc_t> >::_M_default_append           ` |
| 4.42 | `CAGCDecompressorLibrary::decompress_contig                                                ` |
| 4.32 | `CAGCDecompressorLibrary::decompress_segment                                               ` |
| 4.22 | `CSegment::get                                                                             ` |
| 2.64 | `__memmove_avx512_unaligned_erms                                                           ` |
| 2.60 | `CCollection_V3::load_batch_contig_names                                                   ` |
| 2.09 | `CSegment::tuples2bytes                                                                    ` |
| 2.02 | `CCollection_V3::deserialize_contig_names                                                  ` |
| 1.26 | `CArchive::GetPart                                                                         ` |
| 1.14 | `CCollection_V3::zstd_decompress                                                           ` |
| 0.87 | `CCollection_V3::decode_split                                                              ` |
| 0.75 | `CCollection_V3::split_string                                                              ` |
| 0.74 | `CLZDiff_V2::Decode                                                                        ` |

### N = 100: profiled pass 262.3 s for 10 000 windows; share of samples: 78.69%  agc_get_ctg_seq;     21.31%  [other]

top 20 by self time:

| % | symbol |
|---:|---|
| 60.32 | `CCollection_V3::deserialize_contig_details                                                ` |
| 5.29 | `std::vector<segment_desc_t, std::allocator<segment_desc_t> >::_M_default_append           ` |
| 3.22 | `__memset_avx512_unaligned_erms                                                            ` |
| 2.18 | `__memmove_avx512_unaligned_erms                                                           ` |
| 0.76 | `CCollection_V3::decode_split                                                              ` |
| 0.61 | `std::vector<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> ` |
| 0.26 | `CCollection_V3::split_string                                                              ` |
| 0.25 | `cfree@GLIBC_2.2.5                                                                         ` |
| 0.24 | `operator delete                                                                           ` |
| 0.15 | `CCollection_V3::deserialize_contig_names                                                  ` |
| 0.15 | `std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >::_M_replac` |
| 0.13 | `std::vector<CCollection_V3::contig_desc_t, std::allocator<CCollection_V3::contig_desc_t> >` |
| 0.10 | `CSegment::tuples2bytes                                                                    ` |
| 0.08 | `std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >::_M_mutate` |
| 0.08 | `CCollection_V3::clear_batch_contig                                                        ` |
| 0.04 | `operator new                                                                              ` |
| 0.04 | `CSegment::get                                                                             ` |
| 0.03 | `malloc                                                                                    ` |
| 0.03 | `std::vector<int, std::allocator<int> >::_M_fill_insert                                    ` |
| 0.03 | `CAGCDecompressorLibrary::GetContigString                                                  ` |

top 20 by children time:

| % | symbol |
|---:|---|
| 78.69 | `std::thread::_State_impl<std::thread::_Invoker<std::tuple<par_for<main::{lambda()#1}::oper` |
| 78.69 | `agc_get_ctg_seq                                                                           ` |
| 78.69 | `CAGCDecompressorLibrary::GetContigString                                                  ` |
| 78.39 | `CCollection_V3::get_contig_desc                                                           ` |
| 74.24 | `CCollection_V3::load_batch_contig_details                                                 ` |
| 71.87 | `CCollection_V3::deserialize_contig_details                                                ` |
| 7.35 | `__memset_avx512_unaligned_erms                                                            ` |
| 5.53 | `std::vector<segment_desc_t, std::allocator<segment_desc_t> >::_M_default_append           ` |
| 3.22 | `CCollection_V3::load_batch_contig_names                                                   ` |
| 2.37 | `CCollection_V3::deserialize_contig_names                                                  ` |
| 2.18 | `__memmove_avx512_unaligned_erms                                                           ` |
| 1.40 | `CArchive::GetPart                                                                         ` |
| 1.01 | `CCollection_V3::decode_split                                                              ` |
| 0.97 | `CCollection_V3::zstd_decompress                                                           ` |
| 0.86 | `CCollection_V3::split_string                                                              ` |
| 0.61 | `std::vector<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> ` |
| 0.44 | `CArchive::get_part                                                                        ` |
| 0.25 | `cfree@GLIBC_2.2.5                                                                         ` |
| 0.25 | `CAGCDecompressorLibrary::decompress_contig                                                ` |
| 0.24 | `CAGCDecompressorLibrary::decompress_segment                                               ` |

### N = 200: profiled pass 353.4 s for 10 000 windows; share of samples: 80.26%  agc_get_ctg_seq;     19.74%  [other]

top 20 by self time:

| % | symbol |
|---:|---|
| 62.60 | `CCollection_V3::deserialize_contig_details                                                ` |
| 5.73 | `std::vector<segment_desc_t, std::allocator<segment_desc_t> >::_M_default_append           ` |
| 3.42 | `__memset_avx512_unaligned_erms                                                            ` |
| 2.34 | `__memmove_avx512_unaligned_erms                                                           ` |
| 0.50 | `CCollection_V3::decode_split                                                              ` |
| 0.42 | `std::vector<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> ` |
| 0.16 | `CCollection_V3::split_string                                                              ` |
| 0.16 | `cfree@GLIBC_2.2.5                                                                         ` |
| 0.15 | `operator delete                                                                           ` |
| 0.10 | `std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >::_M_replac` |
| 0.09 | `CCollection_V3::deserialize_contig_names                                                  ` |
| 0.09 | `std::vector<CCollection_V3::contig_desc_t, std::allocator<CCollection_V3::contig_desc_t> >` |
| 0.07 | `CSegment::tuples2bytes                                                                    ` |
| 0.05 | `std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >::_M_mutate` |
| 0.04 | `CCollection_V3::clear_batch_contig                                                        ` |
| 0.04 | `std::vector<int, std::allocator<int> >::_M_fill_insert                                    ` |
| 0.03 | `CSegment::get                                                                             ` |
| 0.03 | `operator new                                                                              ` |
| 0.03 | `malloc                                                                                    ` |
| 0.02 | `CAGCDecompressorLibrary::GetContigString                                                  ` |

top 20 by children time:

| % | symbol |
|---:|---|
| 80.26 | `std::thread::_State_impl<std::thread::_Invoker<std::tuple<par_for<main::{lambda()#1}::oper` |
| 80.26 | `agc_get_ctg_seq                                                                           ` |
| 80.25 | `CAGCDecompressorLibrary::GetContigString                                                  ` |
| 80.04 | `CCollection_V3::get_contig_desc                                                           ` |
| 76.86 | `CCollection_V3::load_batch_contig_details                                                 ` |
| 74.27 | `CCollection_V3::deserialize_contig_details                                                ` |
| 7.25 | `__memset_avx512_unaligned_erms                                                            ` |
| 5.85 | `std::vector<segment_desc_t, std::allocator<segment_desc_t> >::_M_default_append           ` |
| 2.34 | `__memmove_avx512_unaligned_erms                                                           ` |
| 2.12 | `CCollection_V3::load_batch_contig_names                                                   ` |
| 1.60 | `CCollection_V3::deserialize_contig_names                                                  ` |
| 1.48 | `CArchive::GetPart                                                                         ` |
| 1.10 | `CCollection_V3::zstd_decompress                                                           ` |
| 0.67 | `CCollection_V3::decode_split                                                              ` |
| 0.59 | `CCollection_V3::split_string                                                              ` |
| 0.42 | `std::vector<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> ` |
| 0.40 | `CArchive::get_part                                                                        ` |
| 0.19 | `CAGCDecompressorLibrary::decompress_contig                                                ` |
| 0.18 | `CAGCDecompressorLibrary::decompress_segment                                               ` |
| 0.17 | `CSegment::get                                                                             ` |

### N = 558: profiled pass 379.1 s for 10 000 windows; share of samples: 81.61%  agc_get_ctg_seq;     18.39%  [other]

top 20 by self time:

| % | symbol |
|---:|---|
| 65.14 | `CCollection_V3::deserialize_contig_details                                                ` |
| 6.25 | `std::vector<segment_desc_t, std::allocator<segment_desc_t> >::_M_default_append           ` |
| 3.60 | `__memset_avx512_unaligned_erms                                                            ` |
| 2.04 | `__memmove_avx512_unaligned_erms                                                           ` |
| 0.31 | `CCollection_V3::decode_split                                                              ` |
| 0.26 | `std::vector<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> ` |
| 0.09 | `CCollection_V3::split_string                                                              ` |
| 0.06 | `cfree@GLIBC_2.2.5                                                                         ` |
| 0.06 | `CSegment::tuples2bytes                                                                    ` |
| 0.06 | `std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >::_M_replac` |
| 0.05 | `operator delete                                                                           ` |
| 0.05 | `CCollection_V3::deserialize_contig_names                                                  ` |
| 0.04 | `std::vector<CCollection_V3::contig_desc_t, std::allocator<CCollection_V3::contig_desc_t> >` |
| 0.04 | `std::vector<int, std::allocator<int> >::_M_fill_insert                                    ` |
| 0.03 | `CSegment::get                                                                             ` |
| 0.03 | `std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >::_M_mutate` |
| 0.02 | `CCollection_V3::clear_batch_contig                                                        ` |
| 0.02 | `CAGCDecompressorLibrary::GetContigString                                                  ` |
| 0.02 | `operator new                                                                              ` |
| 0.02 | `malloc                                                                                    ` |

top 20 by children time:

| % | symbol |
|---:|---|
| 81.61 | `std::thread::_State_impl<std::thread::_Invoker<std::tuple<par_for<main::{lambda()#1}::oper` |
| 81.61 | `agc_get_ctg_seq                                                                           ` |
| 81.61 | `CAGCDecompressorLibrary::GetContigString                                                  ` |
| 81.41 | `CCollection_V3::get_contig_desc                                                           ` |
| 79.32 | `CCollection_V3::load_batch_contig_details                                                 ` |
| 76.80 | `CCollection_V3::deserialize_contig_details                                                ` |
| 6.88 | `__memset_avx512_unaligned_erms                                                            ` |
| 6.25 | `std::vector<segment_desc_t, std::allocator<segment_desc_t> >::_M_default_append           ` |
| 2.04 | `__memmove_avx512_unaligned_erms                                                           ` |
| 1.44 | `CArchive::GetPart                                                                         ` |
| 1.17 | `CCollection_V3::load_batch_contig_names                                                   ` |
| 1.08 | `CCollection_V3::zstd_decompress                                                           ` |
| 0.96 | `CCollection_V3::deserialize_contig_names                                                  ` |
| 0.44 | `CArchive::get_part                                                                        ` |
| 0.41 | `CCollection_V3::decode_split                                                              ` |
| 0.36 | `CCollection_V3::split_string                                                              ` |
| 0.26 | `std::vector<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> ` |
| 0.18 | `CAGCDecompressorLibrary::decompress_contig                                                ` |
| 0.17 | `CAGCDecompressorLibrary::decompress_segment                                               ` |
| 0.16 | `CSegment::get                                                                             ` |



## What the numbers show (counters and profiles; no cause beyond them)

- **The N effect of AGC windows is the metadata batch.** AGC time per random window: 1.15 ms (N = 50),
  26.4 (100), 35.7 (200), 37.8 ms (558). Counters, file order (random sample per request): at
  N >= 100 the median request performs 1 `load_batch_contig_names` + 1 `load_batch_contig_details` + 1 `batch_clear`,
  3.8 MB of zstd input -> 15.6 MB output, 105 MB of allocations (17-68 k `new` calls); at N = 50 (T2T + 50 = 51 samples
  = 2 batches of 50) 0.22 batch loads per request, 17 KB in -> 15 KB out, 64 `new` calls, 0.47 MB. The same 1 000 windows
  **sorted by sample**: 0 batch loads at every N, 2 zstd calls, 17 KB in / 15 KB out, 42-67 `new` calls, 0.46-0.54 MB -
  identical at N = 50 and N = 558. Profile (self time under agc_get_ctg_seq): `CCollection_V3::deserialize_contig_details`
  55.5 % (N = 50) -> 65.1 % (N = 558), `load_batch_contig_details` 79 % of children time at N = 558. H4 of G1 is what the
  counters show; the growth from N = 100 to 558 follows the batch content (zstd output 8.0 -> 11.2 -> 14.1 MB per load).
- **H1 (fixed per-request cost)**: present and constant in N - one ZSTD_createDCtx / freeDCtx per request
  (agc_decompressor_lib.cpp:184 / :290), 4 096 converted bytes; at N = 50 the whole request is 64 allocations / 0.47 MB.
  Not the N dependence.
- **H3 (pack, not W)**: constant in N - every window decodes one segment of 60 031 reference bytes + ~560 delta bytes into
  60 039 assembled bytes for 4 096 returned (ratio 14.7), through segment.cpp:269 (reference part, ~15 KB -> 17 KB) and
  :306 (delta pack, ~5 KB). This is the N-independent floor: 1.15 ms per window at N = 50 against 0.005 ms for refrel3 q4k.
- **H2 (position in the contig)**: `dc_desc_scanned` 256-824 and `desc_segments_copied` 673-2 146 per request vary with
  the sample set (release-2 assemblies carry more segments per contig), not with the request order (sorted == file order);
  no separate N effect visible in the counters.
- **H5**: library path only; the CLI was not measured in M6 (M1 has the CLI rows).
- **1 Mb regions**: the same batch effect (AGC 294 -> 26 requests/s, 18 segments decoded per request at every N);
  **whole samples**: flat in N for both tools (AGC 7.6 s, refrel3 1.3 s per sample at 1 thread; 2.8 / 0.23 s at 16).
- **refrel3**: windows 200 884 -> 145 222 /s (q4k, 1 thread) from N = 50 to 558, regions and whole samples flat; the
  window decrease is in the numbers, its cause is not measured here (no counters on refrel3 in M6).

Curves: `curves_timing.csv` (N, tool, dataset, kind, threads, median / min / max / 9 raw s, requests per s, s per
request, peak RSS, open time, truth check), `curves_counters.csv` (median / mean / p90 / max per counter), and
`curves_zstd_sites.csv` (per zstd call site). Raw logs: logs/N*/ (RUN lines, time -v, counters, perf reports).
