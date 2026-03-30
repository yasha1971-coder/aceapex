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
