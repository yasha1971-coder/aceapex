# ACEAPEX Benchmark Results

## Hardware

AMD EPYC 4344P 8-Core (Zen 4) | 125 GB DDR5 | NVMe RAID1

## enwik9 (1,000,000,000 bytes, 8 threads)

| Metric       | Value                                      |
| ------------ | ------------------------------------------ |
| Ratio        | 2.973x                                     |
| Encode       | 485 MB/s (wall clock)                      |
| Decode       | 4.2 GB/s algorithmic / 2.3 GB/s wall clock |
| Integrity    | XXH3-64                                    |

Note: algorithmic speed excludes file I/O. Wall clock includes
full pipeline: file read, entropy decompress, LZ77 decode.

## Pipeline (enwik9, encode, 8 threads)

| Phase           | Time  |
| --------------- | ----- |
| mmap input      | 0.51s |
| LZ77 match      | 0.62s |
| lit / zstd-3    | 0.73s |
| FSE off/len/cmd | 0.06s |
| XXH3 integrity  | 0.03s |
| **Total**       | **1.95s** |

## Pipeline (enwik9, decode, 8 threads)

| Phase                    | Time  |
| ------------------------ | ----- |
| lit + fse (parallel)     | 0.138s |
| LZ77 reconstruct         | 0.091s |
| **Total algorithmic**    | **0.241s** |

## Silesia Corpus (8 threads)

| File    | Size    | Ratio   | Encode     | Decode          |
| ------- | ------- | ------- | ---------- | --------------- |
| dickens | 9.7 MB  | 2.616x  | ~320 MB/s  | 2.4 GB/s alg.  |
| mozilla | 51 MB   | 2.656x  | ~560 MB/s  | 3.6 GB/s alg.  |
| nci     | 33 MB   | 11.041x | ~1300 MB/s | 6.2 GB/s alg.  |
| samba   | 21 MB   | 3.972x  | ~670 MB/s  | 3.9 GB/s alg.  |
| xml     | 5.2 MB  | 6.931x  | ~680 MB/s  | 3.3 GB/s alg.  |
| webster | 41 MB   | 3.032x  | ~480 MB/s  | 3.6 GB/s alg.  |

## Measurement Notes

Algorithmic speed = data size / algorithm time (excludes file I/O).
This is the standard methodology used by lzbench and similar tools.
Wall clock includes all I/O and system overhead.

## Build

    sudo apt-get install -y libzstd-dev g++
    git clone https://github.com/yasha1971-coder/aceapex
    cd aceapex && make
