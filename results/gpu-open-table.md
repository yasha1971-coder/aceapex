# Open profile across GPUs (scripts/colab_gpu_open.sh, profile BS 16K / LIT 64K)

chr1 (253 935 557 B), ms, median of 7; every row bit-perfect (FNV of the GPU output == original),
commit 907a470, Colab 2026-09-29, CUDA 12.8, driver 580.82.07, nvCOMP 5.3.0.16.
Logs: results/colab-2026-09-29-<gpu>-gpu-open.log. open = 0 nvCOMP calls.

Archive bytes (identical on every machine; == pinned on all 3 Colab hosts):
| corpus | zstd | rans | open |
|---|---|---|---|
| chr1 (253 935 557 B) | 69 410 925 | 69 106 957 | 67 975 888 |
| t2t (3 156 259 565 B, ace-core) | 902 319 887 | 898 903 131 | 887 641 942 |

## Stages
| GPU (sm) | archive | tok | lit | unpack | match | on-device | +H2D | GB/s on-device |
|---|---|---|---|---|---|---|---|---|
| T4 (75) | zstd | 2.767 | 11.941 | 4.188 | 10.617 | 29.512 | 35.057 | 8.60 |
| T4 (75) | rans | 1.181 | 12.031 | 4.176 | 10.632 | 28.020 | 33.539 | 9.06 |
| T4 (75) | open | 1.080 | 4.370 | 4.707 | 10.355 | 20.512 | 25.940 | 12.38 |
| A100-SXM4-40GB (80) | zstd | 0.879 | 5.399 | 0.750 | 2.843 | 9.870 | 15.408 | 25.73 |
| A100-SXM4-40GB (80) | rans | 0.980 | 5.499 | 0.752 | 2.841 | 10.071 | 15.589 | 25.22 |
| A100-SXM4-40GB (80) | open | 1.103 | 1.377 | 0.858 | 2.831 | 6.170 | 11.590 | 41.15 |
| RTX PRO 6000 Blackwell SE (120) | zstd | 0.485 | 2.960 | 0.464 | 1.308 | 5.216 | 6.421 | 48.68 |
| RTX PRO 6000 Blackwell SE (120) | rans | 0.955 | 3.028 | 0.466 | 1.298 | 5.747 | 6.946 | 44.19 |
| RTX PRO 6000 Blackwell SE (120) | open | 0.948 | 0.968 | 0.508 | 1.294 | 3.719 | 4.897 | 68.29 |
| L4 (89) | — | chr1 download truncated; fixtures 5/5 bit-perfect; re-run pending | | | | | | |

Repeat on the Blackwell host (3f09fcf, same session, chr1 from the work dir): on-device zstd 5.199,
rans 5.696, open 3.719 ms (68.3 GB/s) - open identical to the first run, zstd/rans within 0.9 %.

open vs zstd on-device: T4 -30.5 %, A100 -37.5 %, Blackwell -28.7 %.

## Parts of the open archive, ms
| GPU | seq | cse | gap | val | plain | bases | case | exceptions |
|---|---|---|---|---|---|---|---|---|
| T4 | 2.095 | 0.695 | 0.624 | 0.596 | 0.665 | 2.776 | 0.245 | 1.715 |
| A100 | 0.483 | 0.153 | 0.136 | 0.113 | 0.693 | 0.566 | 0.070 | 0.229 |
| Blackwell | 0.310 | 0.088 | 0.068 | 0.049 | 0.602 | 0.260 | 0.033 | 0.217 |

T4 before gpu-case (19ffed7): on-device 22.56, unpack 6.56 (bases 1.90, case 2.80, exceptions 1.84).
