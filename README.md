# ACEAPEX

Lossless compression with parallel block decode.

## Benchmarks (lzbench, in-memory, AMD EPYC 4344P)

| Compressor | Compress | Decompress | Ratio | File |
|------------|----------|------------|-------|------|
| zstd -3    | 1071 MB/s | 3383 MB/s | 8.45% | nci |
| aceapex -2 -I8 | 885 MB/s | 10200 MB/s | 8.56% | nci |
| zstd -3    | 856 MB/s | 3293 MB/s | 11.89% | xml |
| aceapex -2 -I8 | 885 MB/s | 4697 MB/s | 12.93% | xml |

All results BIT-PERFECT (MD5 verified).

## Two formats

**ACEPX2** (v1.0) — maximum throughput, 2.8GB RAM encode
**ACEPX3** (v2-dev) — streaming, 23MB RAM encode, parallel decode

## Build

    sudo apt-get install -y libzstd-dev g++
    git clone https://github.com/yasha1971-coder/aceapex
    cd aceapex && bash build.sh

## Usage

    ./aceapex c --in file --out file.acpx --threads 8
    ./aceapex d --in file.acpx --out file_restored

## v2-dev branch

Streaming encode (23MB RAM), C API, Python bindings, ACEPX3 format.
See [v2-dev](https://github.com/yasha1971-coder/aceapex/tree/v2-dev)

## Honest status

Research-grade. Encode slower than zstd. 
Decode 3-5x faster than zstd on structured data.
Built with Claude AI assistance.

## License

MIT
