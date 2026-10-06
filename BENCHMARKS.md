# BENCHMARKS - refrel3 / ACEAPEX measurements (one structure per axis; numbers only from the named evidence)

Each axis: question - protocol - hardware - versions and flags - table - evidence. "Where we lose" is a section of its
own. Nothing here is an estimate unless marked "calculation".

## 1. Size per assembly, HPRC cohort

- Protocol: `research/agc_vs_refrel3/PROTOCOL_AGC558.md` (frozen, SHA-256 in `agc558/PROTOCOL_AGC558.sha256`).
- Versions: refrel3 v1 (research/refrel @ 5b6d5ce, gcc 11.4 -O3 -march=native -funroll-loops); AGC 3.2.4 from source
  e67e3fc (-O3 -march=native), `agc create -d -k 31 -l 20 -s 60000 -b 50 -t 16`, T2T first.

| N | refrel3 q4k (no block hashes) | refrel3 q16k (no block hashes) | AGC with T2T, minus T2T alone | T2T |
|---:|---:|---:|---:|---|
| 50 | 16.33 MB | 13.14 MB | 8.65 MB | AGC: inside the archive, 707 323 301 B; refrel3: the decoded FASTA, 3 156 259 565 B |
| 558 | 16.22 MB | 13.04 MB | 5.40 MB | same |

With block hashes (as frozen in the manifest): q4k 22.10 MB, q16k 14.51 MB per assembly (558).
Evidence: `research/agc_vs_refrel3/README.md` (N = 50), `research/agc_vs_refrel3/agc558/sizes558.txt` and `RUN.md`
(N = 558; AGC create 1:17:21, peak RSS 34.7 GB; integrity listset / listctg / getset XXH3 558 / 558).

## 2. CPU random access, N = 50 (in process)

- Protocol: `research/agc_vs_refrel3/README.md` (truth from the source FASTA), runner `run_all.sh`; ace-core AMD EPYC
  4344P 8C/16T, 125 GB, Ubuntu 22.04; 3 warm-ups + 9 timed runs; every answer SHA-256 == truth.

| task | threads | refrel3 q4k | refrel3 q16k | AGC with T2T | AGC no reference |
|---|---:|---:|---:|---:|---:|
| 10 000 windows x 8 192, windows/s | 1 | 128 459 | 74 819 | 988 | 12 608 |
| | 16 | 994 036 | 685 730 | 4 478 | 108 259 |
| 1 000 regions, regions/s | 1 | 22 429 | 20 593 | 1 074 | 5 339 |
| | 16 | 148 765 | 136 184 | 4 240 | 39 064 |
| whole sample, s per sample (first 4) | 1 | 1.308 | 1.279 | 7.761 | 7.379 |
| | 16 | 0.233 | 0.233 | 2.994 | 2.778 |

Evidence: `research/agc_vs_refrel3/SUMMARY_runs.md`, `logs/`.

## 3. CPU random access, N = 558 (in process; AGC CLI separately)

- Protocol: `research/agc_vs_refrel3/PROTOCOL_AGC558.md` (frozen); AGC archive = one create, integrity PASS; truth from
  the v1 decode with source XXH3 checks; same host; 3 + 9; every answer SHA-256 == truth (192 runs).

| task | threads | refrel3 q4k | refrel3 q16k | AGC in process | AGC CLI |
|---|---:|---:|---:|---:|---:|
| 10 000 windows x 8 192, windows/s | 1 | 94 324 | 58 344 | 26.6 | 27.7 |
| | 16 | 840 831 | 552 517 | 94.8 | 26.9 |
| 1 000 regions, regions/s | 1 | 21 590 | 18 761 | 26.1 | 26.5 |
| | 16 | 136 780 | 125 818 | 93.6 | 26.5 |
| whole sample, s per sample (first 4) | 1 | 1.312 | 1.284 | 7.608 | - |
| | 16 | 0.233 | 0.233 | 2.869 | - |

Evidence: `research/agc_vs_refrel3/agc558/RUN.md`, `logs/`.

## 4. One-thread full decode D_Q (window law), HPRC N = 4

- Protocol: hw-apex-bench PR #63 `review/axis3/WINDOW_LAW.md`; evidence `review/axis3/results/ace-core-2026-10-05-407088c-dq/`
  (commit 1351dcf): decode to FASTA bytes, one thread pinned, 3 + 9, SHA-256 48 / 48.

| format | Q (mean independent unit) | D_Q, GB/s |
|---|---:|---:|
| refrel3 q4k | 4 147 B | 0.876 |
| refrel3 q16k | 16 589 B | 0.915 |
| BGZF (htslib 1.24, level 6) | 65 205 B | 0.876 |
| zstd seekable (1.5.7, level 3) | 16 384 B | 0.808 |
| lz4 frame (1.10.0, 4 MiB independent blocks) | 4 191 897 B | 1.925 |
| OpenZL v0.3.0 | - | FAILED at build (input limit ~1.5 GiB) |

## 5. Corruption, refrel3 v1 (CPU)

- Evidence `research/refrel/logs/v1-corrupt-2026-10-04.log`: 6 kinds x 10 000 per archive kind, 10 s watchdog.
  With block XXH3: 0 silent (q4k and q16k); without block hashes and without verification: 1 798 (q4k) / 2 145 (q16k)
  silent; 240 000 cases, 0 hang, 0 crash.

## 6. GPU (ACEPX2 open archive; other hardware - never in a CPU column)

- Evidence: paper7 (DOI 10.5281/zenodo.23113139), logs in commit af5f56b; LEDGER C-044, C-050, C-051, C-103.
  T2T resident, 65 536 windows of 1 KiB: 5 024 646 / s (RTX PRO 6000 Blackwell), 4 626 634 / s (H100); 32 KiB windows
  109.22 / 103.60 GB/s; ten HPRC assemblies 7.71 GB on one H100, 2 967 827 windows / s across all ten.

## Where we lose

- **Size against AGC:** at N = 558 AGC with T2T needs 5.40 MB per assembly, refrel3 13.04 (q16k) - 16.22 (q4k) MB
  without block hashes: 2.4 - 3.0 x larger (section 1). At N = 50 the gap was 1.5 - 1.9 x (8.65 against 13.14 - 16.33
  MB): with a larger cohort AGC wins by more (two measurements; the cause is not stated here).
- **One-thread full decode:** lz4 frame 1.925 GB/s against refrel3 0.876 - 0.915 GB/s; BGZF equals refrel3 q4k (section 4).
- **One region on the GPU:** slower than one CPU core (537.2 µs H100, 490.9 µs Blackwell against 137.3 / 107.2 µs on the
  same hosts, C-103); the GPU pays off only in batches.
- **Training:** no speed-up of a training step measured (C-086: batch fetch 0.20 % of the step for this path, 0.02 % for
  raw sequence in VRAM).
- **Coordinates:** translation of reference coordinates to haplotype coordinates is not implemented; fetch works only in
  the coordinates of each assembly.
