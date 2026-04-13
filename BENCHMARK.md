# ACEAPEX Benchmark Results

## Hardware
CPU: AMD EPYC 4344P 8-core | RAM: 32GB | NVMe: 8.5 GB/s read

## enwik9 (1,000,000,000 bytes)

| Metric | Value | Notes |
|--------|-------|-------|
| Ratio | 2.956x | BPB: 2.706 |
| Encode | 438 MB/s | 8 threads, mmap input |
| Encode | 160 MB/s | 1 thread |
| Decode | 11089 MB/s | in-memory (MAP_POPULATE) |
| Hash | XXH3-64 | integrity check |
| Status | ✅ BIT-PERFECT | |

## Thread scaling (encode, enwik9)
| Threads | MB/s | Speedup |
|---------|------|---------|
| 1 | 160 | 1.0x |
| 2 | 246 | 1.5x |
| 4 | 282 | 1.8x |
| 8 | 438 | 2.7x |

## Pipeline timing (enwik9, 8 threads)
| Phase | Time |
|-------|------|
| mmap input | 0.82s |
| LZ77 match | 0.69s |
| lit/zstd-3 | 0.76s |
| FSE off/len/cmd | 0.07s |
| XXH3 integrity | 0.04s |
| **Total** | **2.28s** |

## Decode note
Decode uses mmap with MAP_POPULATE — file pre-loaded into RAM.
NVMe read speed: 8.5 GB/s. Pure CPU decode: ~11 GB/s.

## vs Industry (enwik9)
| Compressor | Ratio | Encode | Decode |
|-----------|-------|--------|--------|
| zstd -3 | 2.84x | ~500 MB/s | ~1800 MB/s |
| zstd -19 | ~3.33x | ~13 MB/s | ~900 MB/s |
| **ACEAPEX** | **2.956x** | **438 MB/s** | **11089 MB/s** |

## Silesia Corpus (all files, 8 threads, BIT-PERFECT)

| File | Size | Ratio | Encode MB/s | Decode MB/s |
|------|------|-------|-------------|-------------|
| dickens | 9.7MB | 2.62x | 316 | 9712 |
| mozilla | 51MB | 2.57x | 471 | 8538 |
| mr | 9.9MB | 2.84x | 421 | 11957 |
| nci | 33MB | 10.31x | 873 | 9973 |
| ooffice | 6.1MB | 1.86x | 341 | 8656 |
| osdb | 9.9MB | 2.54x | 424 | 9214 |
| reymont | 6.5MB | 2.98x | 385 | 7001 |
| samba | 21MB | 3.85x | 569 | 8050 |
| sao | 7.3MB | 1.30x | 285 | 12406 |
| webster | 40MB | 3.03x | 448 | 8926 |
| x-ray | 8.5MB | 1.39x | 286 | 10412 |
| xml | 5.2MB | 6.18x | 632 | 8082 |
