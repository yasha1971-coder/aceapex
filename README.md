# ACEAPEX

High-throughput lossless compression. Global analysis at encode time. Parallel block decode at runtime.

## Benchmarks (enwik9, 1GB, AMD EPYC 4344P 8-Core Zen 4, 8 threads, wall clock)

| Metric     | Value          |
| ---------- | -------------- |
| Ratio      | 2.973x         |
| Encode     | 485 MB/s       |
| Decode     | 11299 MB/s*    |
| Integrity  | XXH3-64        |
| Status     | BIT-PERFECT    |

*Decode: in-memory (MAP_POPULATE). Full pipeline including entropy coding.

## vs Industry (enwik9)

| Compressor  | Ratio  | Encode    | Decode      |
| ----------- | ------ | --------- | ----------- |
| zstd -3     | 2.84x  | ~500 MB/s | ~1800 MB/s  |
| zstd -19    | ~3.33x | ~13 MB/s  | ~900 MB/s   |
| ACEAPEX     | 2.973x | 485 MB/s  | 11299 MB/s  |

Full Silesia corpus results: [BENCHMARK.md](BENCHMARK.md)

## Core Idea

Standard LZ77 codecs face a tradeoff:
- Global context gives better ratio but requires sequential decode
- Independent blocks enable parallel decode but lose ratio

ACEAPEX separates these responsibilities:
- Encode: global analysis, full match search across entire input
- Decode: block-parallel reconstruction via precomputed per-block stream offsets

Cross-block LZ77 matches are resolved into block-local form at encode time.

## Key Properties

- Bit-perfect (XXH3-64 verified on every run)
- Global-analysis encoding with block-local decode representation
- Parallel block decode, scales with cores
- Single-file C++17, libzstd only

## Build

    sudo apt-get install -y libzstd-dev g++
    g++ -O3 -march=native -funroll-loops -std=c++17 \
        -o aceapex src/aceapex_main.cpp -lpthread -lzstd

## Usage

    ./aceapex c --in myfile --out myfile.aet --threads 8
    ./aceapex d --in myfile.aet --out myfile_restored
    ./aceapex t --in myfile --threads 8

## Status

Research-grade. One data point on a tradeoff curve.

## License

MIT
