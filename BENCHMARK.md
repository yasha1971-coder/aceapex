# ACEAPEX Benchmark Results

## Hardware

AMD EPYC 4344P 8-Core (Zen 4) | 125 GB DDR5 | NVMe RAID1 8.5 GB/s read

## enwik9 (1,000,000,000 bytes, 8 threads)

| Metric       | Value          |
| ------------ | -------------- |
| Ratio        | 2.973x         |
| Compress     | 485 MB/s       |
| Decompress   | 11299 MB/s     |
| Integrity    | XXH3-64        |
| Status       | ✅ BIT-PERFECT  |

## Pipeline (enwik9, 8 threads)

| Phase           | Time      |
| --------------- | --------- |
| mmap input      | 0.82s     |
| LZ77 match      | 0.69s     |
| lit / zstd-3    | 0.76s     |
| FSE off/len/cmd | 0.07s     |
| XXH3 integrity  | 0.04s     |
| **Total**       | **2.06s** |

## vs Industry (enwik9)

| Compressor   | Ratio  | Compress  | Decompress |
| ------------ | ------ | --------- | ---------- |
| zstd -3      | 2.84x  | ~500 MB/s | ~1800 MB/s |
| zstd -19     | ~3.33x | ~13 MB/s  | ~900 MB/s  |
| **ACEAPEX**  | **2.973x** | **485 MB/s** | **11299 MB/s** |

## Silesia Corpus (all files, 8 threads, BIT-PERFECT)

| File    | Size  | Ratio  | Compress MB/s | Decompress MB/s |
| ------- | ----- | ------ | ------------- | --------------- |
| dickens | 9.7MB | 2.62x  | 323           | 7132            |
| mozilla | 51MB  | 2.59x  | 566           | 7705            |
| mr      | 9.9MB | 2.84x  | 391           | 7709            |
| nci     | 33MB  | 10.83x | 1316          | 9485            |
| ooffice | 6.1MB | 1.86x  | 337           | 6607            |
| osdb    | 9.9MB | 2.52x  | 440           | 6410            |
| reymont | 6.5MB | 2.99x  | 396           | 5961            |
| samba   | 21MB  | 3.91x  | 679           | 7323            |
| sao     | 7.3MB | 1.30x  | 303           | 11633           |
| webster | 40MB  | 3.03x  | 482           | 7401            |
| x-ray   | 8.5MB | 1.39x  | 278           | 7884            |
| xml     | 5.2MB | 6.82x  | 682           | 5327            |

## Notes

Decompress uses mmap with MAP_POPULATE — data pre-loaded into RAM.
NVMe read speed: 8.5 GB/s. Pure CPU decode: ~11 GB/s.
