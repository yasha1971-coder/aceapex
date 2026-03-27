# ACEAPEX v2

**High-throughput lossless compression with global-context encoding and parallel block decode.**

## Key Result (enwik9, 1GB, AMD EPYC 4344P, 8 threads)

| Metric | Value |
|--------|-------|
| Ratio | 3.747x |
| Encode | 803 MB/s |
| Decode | **10.46 GB/s** |
| Verification | SHA-256 bit-perfect |

## Head-to-Head (same machine, same dataset, 8 threads)

| Codec | Ratio | Encode | Decode |
|-------|-------|--------|--------|
| LZ4 -9 | 2.794x | 55 MB/s | 2703 MB/s |
| zstd -3 | 3.187x | 1613 MB/s | 1379 MB/s |
| zstd -9 | 3.759x | 245 MB/s | 1429 MB/s |
| zstd -19 | 4.245x | 13 MB/s | 1420 MB/s |
| **ACEAPEX v2** | **3.747x** | **803 MB/s** | **10460 MB/s** |

All results on enwik9 (1,000,000,000 bytes), AMD EPYC 4344P, Ubuntu 22.04.

## Encode Scaling (enwik9)

| Threads | Encode MB/s | Decode MB/s | Ratio |
|---------|-------------|-------------|-------|
| 1 | 153 | 10032 | 3.747x |
| 2 | 292 | 10601 | 3.747x |
| 4 | 524 | 10435 | 3.747x |
| 8 | 803 | 10460 | 3.747x |

Decode throughput is independent of encode thread count - architectural property.

## Key Properties

- Bit-perfect compression (SHA-256 verified on every run)
- Global-analysis encoding with block-local decode representation
- Parallel block decode (scales independently of encode threading)
- Deterministic output
- Single-file C++17, libzstd only

## Core Idea
Standard LZ77 codecs face a tradeoff:
- Global context gives better ratio but requires sequential decode
- Independent blocks enable parallel decode but lose ratio

ACEAPEX v2 separates these responsibilities:
- **Encode**: global analysis, full match search across entire input
- **Decode**: block-parallel reconstruction via precomputed per-block stream offsets

Cross-block LZ77 matches are resolved into block-local form at encode time.
Decode-time back-references do not cross block boundaries.
This is "global analysis, local decode" — not true global LZ77 decode dependency.
Each decode block knows its exact offset in the global compressed stream.
Decode scales with cores. Ratio is preserved.

## Build
```bash
sudo apt-get install -y libzstd-dev g++
bash build.sh
```

## Usage
```bash
./aceapex c --in myfile --out myfile.aet --threads 8
./aceapex d --in myfile.aet --out myfile_restored
./aceapex t --in myfile --threads 8
```

## Reproduce
```bash
bash scripts/run_bench.sh ./aceapex /path/to/enwik9
```

enwik9: http://mattmahoney.net/dc/enwik9.zip

## License

MIT
