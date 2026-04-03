# ACEAPEX — Benchmark Results

## Hardware
- CPU: AMD EPYC 4344P, 8 cores
- OS: Ubuntu 22.04
- Compiler: g++ -O3 -march=native -funroll-loops -std=c++17
- libzstd: system

## Important Note
**Encode speed figures from earlier versions were incorrect.**
The timer measured only the LZ77 pass, not the zstd entropy coding step.
Corrected encode benchmarks in progress.
Only ratio and decode speed are verified correct.

## enwik9 (1GB, SHA256 verified) — Decode comparison

| Codec | Ratio | Decode MB/s |
|-------|-------|-------------|
| zstd -9 | 3.759x | 1429 |
| zstd -19 | 4.245x | 1420 |
| **ACEAPEX** | **3.896x** | **11609** |

All results SHA-256 bit-perfect verified.

## Canterbury corpus (ratio only, BIT-PERFECT)

| File | Ratio |
|------|-------|
| kennedy.xls | 14.69x |
| ptt5 | 10.20x |
| E.coli | 3.95x |
| world192.txt | 3.64x |
| bible.txt | 3.51x |
| alice29.txt | 2.77x |

## Decode Scaling (enwik9, AMD EPYC 4344P)

| Threads | Decode MB/s |
|---------|-------------|
| 1 | 11558 |
| 2 | 11636 |
| 4 | 11777 |
| 8 | 11719 |
| 16 | 11525 |

Decode throughput is constant (~11,600 MB/s) regardless of thread count.

## Real Game Assets — Decode (BIT-PERFECT)

| File | Size | Ratio | Decode MB/s |
|------|------|-------|-------------|
| H1Emu Launcher.dll | 279MB | 3.25x | 10830 |
| Microsoft.Windows.SDK.NET.dll | 23MB | 4.98x | 6461 |
| H1Emu Launcher.pdb | 2.9MB | 3.72x | 3776 |
| blender-5.1-splash | 1.6GB | 3.21x | 13022 |

## Context vs Oodle (public data)

| Codec | Ratio | Decode MB/s | Notes |
|-------|-------|-------------|-------|
| Oodle Selkie | ~2.6x | 10000+ | fastest Oodle |
| Oodle Kraken | ~3.6x | 2000-4000 | default PS5 |
| Oodle Leviathan | ~4.1x | 600-1200 | highest ratio |
| **ACEAPEX** | **3.896x** | **11600** | ratio near Kraken, speed beyond Selkie |

Oodle figures from public blog posts (cbloomrants.blogspot.com).
Direct comparison on same hardware not available — Oodle SDK is proprietary.
