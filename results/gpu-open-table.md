# Open profile across GPUs (scripts/colab_gpu_open.sh, profile BS 16K / LIT 64K)

One row per (GPU, corpus, archive); ms, median of 7 (chr1) / 3 (t2t); only bit-perfect rows.
Source logs: results/colab-<date>-<gpu>-gpu-open.log (TSV lines).

Archive bytes (identical on every machine; ace-core 2026-09-29):
| corpus | zstd | rans | open |
|---|---|---|---|
| chr1 (253 935 557 B) | 69 410 925 | 69 106 957 | 67 975 888 |
| t2t (3 156 259 565 B) | 902 319 887 | 898 903 131 | 887 641 942 |

| GPU | corpus | archive | tok | lit | unpack | match | on-device | +H2D | GB/s | commit |
|---|---|---|---|---|---|---|---|---|---|---|
| T4 | chr1 | zstd | 2.806 | 12.096 | 4.163 | 10.634 | 29.699 | 35.243 | 8.55 | 5fef973 |
| T4 | chr1 | rans | 1.192 | 12.394 | 4.243 | 10.833 | 28.663 | 34.189 | 8.86 | 5fef973 |
| T4 | chr1 | open | — | — | — | — | — | — | — | 5fef973: illegal instruction, fixed 76d71eb |
