# ACEAPEX — Benchmark Results

## Hardware
- CPU: AMD EPYC 4344P, 8 cores
- OS: Ubuntu 22.04
- Compiler: g++ -O3 -march=native -funroll-loops -std=c++17
- libzstd: system

## Config (breakthrough)
- HASH_SIZE: 0x1FFF (L1 cache fit)
- BLOCK_SIZE: 32KB
- decode: 8 batched threads
- zstd level: 22

## enwik9 (1GB, SHA256 verified)

| Codec | Ratio | Encode MB/s | Decode MB/s |
|-------|-------|-------------|-------------|
| LZ4 -9 | 2.794x | 55 | 2703 |
| zstd -3 | 3.187x | 1613 | 1379 |
| zstd -9 | 3.759x | 245 | 1429 |
| zstd -19 | 4.245x | 13 | 1420 |
| **ACEAPEX** | **3.896x** | **1582** | **11609** |

## Silesia corpus (8 threads, BIT-PERFECT)

| File | Ratio | Encode MB/s | Decode MB/s |
|------|-------|-------------|-------------|
| xml (5MB) | 7.113x | 2084 | 4874 |
| x-ray (8MB) | 1.645x | 1666 | 9036 |
| mozilla (51MB) | 3.076x | 1646 | 7576 |

## Canterbury corpus (BIT-PERFECT)

| File | Ratio | Encode MB/s | Decode MB/s |
|------|-------|-------------|-------------|
| kennedy.xls | 14.69x | 1639 | 2588 |
| ptt5 | 10.20x | 1754 | 2816 |
| E.coli | 3.95x | 1344 | 4915 |
| world192.txt | 3.64x | 1365 | 3398 |
| bible.txt | 3.51x | 1089 | 4012 |
| alice29.txt | 2.77x | 280 | 507 |

## Decode Scaling (enwik9, AMD EPYC 4344P)

| Encode Threads | Encode MB/s | Decode MB/s |
|----------------|-------------|-------------|
| 1 | 212 | 11558 |
| 2 | 429 | 11636 |
| 4 | 827 | 11777 |
| 8 | 1566 | 11719 |
| 16 | 2104 | 11525 |

**Key property: decode throughput is constant (~11,600 MB/s) regardless of encode thread count.**
This is an architectural property, not an optimization artifact.

## Context vs Oodle (public data)

| Codec | Ratio | Decode MB/s | Notes |
|-------|-------|-------------|-------|
| Oodle Selkie | ~2.6x | 10000+ | fastest Oodle, lowest ratio |
| Oodle Kraken | ~3.6x | 2000-4000 | default PS5, balanced |
| Oodle Leviathan | ~4.1x | 600-1200 | highest ratio, slower decode |
| **ACEAPEX** | **3.896x** | **11600** | ratio near Kraken, speed beyond Selkie |

Oodle figures from public blog posts by Charles Bloom (cbloomrants.blogspot.com).
Direct comparison on same hardware not available — Oodle SDK is proprietary.

## Real Game Assets (H1Emu Launcher, BIT-PERFECT)

| File | Size | Ratio | Encode MB/s | Decode MB/s |
|------|------|-------|-------------|-------------|
| H1Emu Launcher.dll | 279MB | 3.25x | 1825 | 10830 |
| Microsoft.Windows.SDK.NET.dll | 23MB | 4.98x | 1986 | 6461 |
| H1Emu Launcher.pdb | 2.9MB | 3.72x | 1780 | 3776 |
| H1Emu Launcher.exe | 265KB | 2.96x | 1004 | 563 |
| blender-5.1-splash (1.6GB raw) | 1.6GB | 3.21x | 2291 | 13022 |

## Single-thread decode (H1Emu Launcher.dll, 279MB)

| Threads | Encode MB/s | Decode MB/s |
|---------|-------------|-------------|
| 1 | 254 | 10513 |
| 8 | 1825 | 10830 |

Decode throughput is nearly constant regardless of thread count.
This is an architectural property of the block layout — not a tuning artifact.
