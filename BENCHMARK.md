# ACEAPEX Benchmark Results

## Hardware

AMD EPYC 4344P 8-Core (Zen 4) | 125 GB DDR5 | NVMe RAID1

## enwik9 (1,000,000,000 bytes, 8 threads)

| Metric       | Value                                      |
| ------------ | ------------------------------------------ |
| Ratio        | 3.021x                                     |
| Encode       | 401 MB/s (wall clock)                      |
| Decode       | 4.2 GB/s algorithmic / 1.7 GB/s wall clock |
| Integrity    | XXH3-64: 1f0533f6be5d8e95                  |

## Silesia Corpus (8 threads)

| File    | Size    | Ratio   | Decode alg. | Status |
| ------- | ------- | ------- | ----------- | ------ |
| dickens | 9.7 MB  | 2.616x  | 2.3 GB/s    | OK     |
| mozilla | 51 MB   | 2.693x  | 3.6 GB/s    | OK     |
| nci     | 32 MB   | 11.089x | 6.3 GB/s    | OK     |
| samba   | 21 MB   | 4.025x  | 3.8 GB/s    | OK     |
| xml     | 5.2 MB  | 6.842x  | 2.9 GB/s    | OK*    |
| webster | 41 MB   | 3.144x  | 3.8 GB/s    | OK     |

*xml: -0.089x vs baseline — known trade-off, documented in TECHNICAL_NOTE.md

## Measurement Notes

Algorithmic speed = data size / algorithm time (excludes file I/O).
Wall clock includes all I/O and system overhead.
All files BIT-PERFECT verified via MD5.
