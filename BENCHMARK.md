# ACEAPEX Benchmark Results

## Hardware
CPU: AMD EPYC 4344P 8-core | RAM: 32GB | NVMe: 8.5 GB/s read

## enwik9 (1,000,000,000 bytes)

| Metric | Value | Notes |
|--------|-------|-------|
| Ratio | 2.956x | BPB: 2.706 |
| Encode | 121 MB/s | 8 threads |
| Encode | 77 MB/s | 1 thread |
| Decode | 11100 MB/s | 8 threads, in-memory (MAP_POPULATE) |
| Status | ✅ BIT-PERFECT | SHA256 verified |

SHA256: 159b85351e5f76e60cbe32e04c677847a9ecba3adc79addab6f4c6c7aa3744bc

## Thread scaling (encode, enwik8)
| Threads | MB/s | Speedup |
|---------|------|---------|
| 1 | 77 | 1.0x |
| 2 | 94 | 1.2x |
| 4 | 107 | 1.4x |
| 8 | 115 | 1.5x |

Note: Poor scaling due to RAM bandwidth contention.
Input (1GB) exceeds L3 cache (32MB).

## Decode note
Decode uses mmap with MAP_POPULATE — file is pre-loaded into RAM
before timing starts. NVMe read speed: 8.5 GB/s.
Pure CPU decode throughput (no I/O): ~11 GB/s.

## Pipeline
- LZ77 match finding: hash chain, epoch-based invalidation
- Literals: zstd-3 (4 parallel threads)
- Offsets/lengths/commands: FSE chunked (3 parallel threads)
- Decode: parallel blocks, mmap output
