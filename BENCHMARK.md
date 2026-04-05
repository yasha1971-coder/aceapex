# ACEAPEX — Benchmark Results

## Hardware
- CPU: AMD EPYC 4344P, 8 cores
- OS: Ubuntu 22.04
- Compiler: g++ -O3 -march=native -funroll-loops -std=c++17

## Important Note
**All numbers are wall-clock time (external `time` command).**
Internal timer measures LZ77 phase only (~11,600 MB/s).
Full pipeline numbers below include entropy coding.

## enwik9 (1GB, SHA-256 verified) — Full Pipeline

| Variant | Ratio | Encode MB/s | Decode MB/s | Notes |
|---------|-------|-------------|-------------|-------|
| A (zstd-22) | 3.896x | 2.5 | 227 | best ratio |
| B (FSE chunked) | 2.227x | 121 | 281 | best encode speed |

All results SHA-256 bit-perfect verified.

## Architecture
- LZ77 with 32KB blocks, parallel workers
- 4 separate global streams: literals, offsets, lengths, commands
- Per-block stream offsets enable fully independent parallel decode
- Each block stores absolute byte offsets into all 4 streams

## Current Bottleneck
Decode: peak RSS 2.6GB causes page faults.
Working on streaming/chunked memory model.
