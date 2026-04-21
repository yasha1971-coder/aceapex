# ACEAPEX Benchmark Results

## Hardware

AMD EPYC 4344P 8-Core (Zen 4) | 125 GB DDR5 | NVMe RAID1

## enwik9 (1,000,000,000 bytes, 8 threads)

| Metric       | Value                                      |
| ------------ | ------------------------------------------ |
| Ratio        | 2.997x                                     |
| Encode       | 391 MB/s (wall clock)                      |
| Decode       | 4.2 GB/s algorithmic / 1.7 GB/s wall clock |
| Integrity    | XXH3-64                                    |

## Pipeline (enwik9, decode, 8 threads)

| Phase                 | Time   |
| --------------------- | ------ |
| lit + fse (parallel)  | 0.138s |
| LZ77 reconstruct      | 0.091s |
| Total algorithmic     | 0.234s |

## Silesia Corpus (8 threads)

| File    | Size    | Ratio   | Decode alg. |
| ------- | ------- | ------- | ----------- |
| dickens | 9.7 MB  | 2.616x  | 2.5 GB/s    |
| mozilla | 51 MB   | 2.684x  | 3.7 GB/s    |
| nci     | 32 MB   | 11.145x | 6.8 GB/s    |
| samba   | 21 MB   | 3.975x  | 3.6 GB/s    |
| xml     | 5.2 MB  | 6.931x  | 3.9 GB/s    |
| webster | 41 MB   | 3.096x  | 3.8 GB/s    |

## Measurement Notes

Algorithmic speed = data size / algorithm time (excludes file I/O).
Wall clock includes all I/O and system overhead.
