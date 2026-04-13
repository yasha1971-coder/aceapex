# ACEAPEX

High-throughput lossless compression. Global analysis at encode time. Parallel block decode at runtime.

## Benchmarks (enwik9, 1GB, AMD EPYC 4344P, 8 threads, wall clock)

| Variant | Ratio | Encode | Decode |
|---------|-------|--------|--------|
| A (zstd-22) | 3.896x | 2.5 MB/s | 227 MB/s |
| B (FSE chunked) | 2.956x | 438 MB/s | 11089 MB/s* |

All results XXH3 bit-perfect verified.
*Decode: in-memory (MAP_POPULATE). Integrity: XXH3-64.

Note: internal LZ77 reconstruction phase runs at ~11,600 MB/s,
but full pipeline (including entropy coding) is shown above.

## Core Idea

Standard LZ77 codecs face a tradeoff:
- Global context gives better ratio but requires sequential decode
- Independent blocks enable parallel decode but lose ratio

ACEAPEX separates these responsibilities:
- **Encode:** global analysis, full match search across entire input
- **Decode:** block-parallel reconstruction via precomputed per-block stream offsets

Cross-block LZ77 matches are resolved into block-local form at encode time.
This is "global analysis, local decode".

## Key Properties

- Bit-perfect (SHA-256 verified on every run)
- Global-analysis encoding with block-local decode representation
- Parallel block decode — scales with cores
- Single-file C++17, libzstd only
- Research-grade code, not a production library

## Download

Binaries in [GitHub Releases](https://github.com/yasha1971-coder/aceapex/releases):

| Platform | File |
|----------|------|
| Linux x64 | aceapex-linux-x64 |
| Windows x64 | aceapex-windows-x64.exe |

## Build
```bash
sudo apt-get install -y libzstd-dev g++
g++ -O3 -march=native -funroll-loops -std=c++17 \
    -o aceapex src/aceapex_main.cpp -lpthread -lzstd
```

## Usage
```bash
./aceapex c --in myfile --out myfile.aet --threads 8
./aceapex d --in myfile.aet --out myfile_restored
./aceapex t --in myfile --threads 8
```

## Status

Research-grade. No claims of universality. One data point on a tradeoff curve.

## License

MIT
