# ACEAPEX Benchmark Results

## Hardware

AMD EPYC 4344P 8-Core (Zen 4) | 125 GB DDR5 | NVMe RAID1

## enwik9 (1,000,000,000 bytes, 8 threads)

| Metric       | Value                                      |
| ------------ | ------------------------------------------ |
| Ratio        | 3.037x                                     |
| Encode       | 307 MB/s (wall clock)                      |
| Decode       | 4.3 GB/s algorithmic / 1.7 GB/s wall clock |
| Integrity    | XXH3-64: 1f0533f6be5d8e95                  |

## Silesia Corpus (8 threads)

| File    | Size    | Ratio   | Decode alg. | vs baseline |
| ------- | ------- | ------- | ----------- | ----------- |
| dickens | 9.7 MB  | 2.596x  | 2.0 GB/s    | -0.020x     |
| mozilla | 51 MB   | 2.710x  | 3.8 GB/s    | +0.054x     |
| nci     | 32 MB   | 11.681x | 6.7 GB/s    | +0.640x     |
| samba   | 21 MB   | 4.138x  | 4.0 GB/s    | +0.166x     |
| xml     | 5.2 MB  | 7.747x  | 3.0 GB/s    | +0.816x     |
| webster | 41 MB   | 3.214x  | 3.9 GB/s    | +0.182x     |

## Measurement Notes

Algorithmic speed = data size / algorithm time (excludes file I/O).
Wall clock includes all I/O and system overhead.
All files BIT-PERFECT verified via MD5.
dickens regression: known trade-off from chain depth, documented in TECHNICAL_NOTE.md
