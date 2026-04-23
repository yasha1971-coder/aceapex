# ACEAPEX

High-throughput lossless compression. Global analysis at encode time. Parallel block decode at runtime.

## Benchmarks (enwik9, 1GB, AMD EPYC 4344P 8-Core Zen 4, 8 threads)

| Metric     | Value                                      |
| ---------- | ------------------------------------------ |
| Ratio      | 3.037x                                     |
| Encode     | 307 MB/s (wall clock)                      |
| Decode     | 4.2 GB/s algorithmic / 1.7 GB/s wall clock |
| Integrity  | XXH3-64, verified on every run             |

Full Silesia corpus results: [BENCHMARK.md](BENCHMARK.md)

## Core Idea

Standard LZ77 codecs face a tradeoff:
- Global context gives better ratio but requires sequential decode
- Independent blocks enable parallel decode but lose ratio

ACEAPEX separates these responsibilities:
- Encode: global analysis, full match search across entire input
- Decode: block-parallel reconstruction via precomputed per-block stream offsets

## Key Properties

- Bit-perfect lossless
- Parallel block decode, scales with cores
- Adaptive hash table with prev chain match finder
- No zstd source required — libzstd-dev only
- Single-file C++17

## Build

    sudo apt-get install -y libzstd-dev g++
    git clone https://github.com/yasha1971-coder/aceapex
    cd aceapex && make

## Usage

    ./aceapex c --in myfile --out myfile.aet --threads 8
    ./aceapex d --in myfile.aet --out myfile_restored
    ./aceapex t --in myfile --threads 8

## Status

Research-grade. Measurement corrections ongoing.

## License

MIT
