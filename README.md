# ACEAPEX

Lossless compression with parallel block decode.

## Benchmarks (enwik9, 1GB, AMD EPYC 4344P 8-Core Zen 4)

| Metric       | Value                    |
| ------------ | ------------------------ |
| Ratio        | 3.037x                   |
| Encode       | 307 MB/s (8 threads)     |
| Decode       | 4.3 GB/s algorithmic (8 threads) |
| Decode T-1   | 796 MB/s (single thread) |
| Integrity    | XXH3-64: 1f0533f6be5d8e95 |

Decode scales 5.4x on 8 cores (68% efficiency, bottlenecked by DDR5 bandwidth).

## Core Idea

Standard LZ77 codecs face a tradeoff:
- Global context → better ratio but sequential decode
- Independent blocks → parallel decode but worse ratio

ACEAPEX separates these responsibilities:
- **Encode:** global match search, hash chain depth 32
- **Decode:** block-parallel via per-block offset index in header

The .acpx format stores a block offset table — parallel decode is a format feature, not an implementation hack.

## Silesia Corpus (8 threads)

| File    | Ratio   | vs zstd -3 |
| ------- | ------- | ---------- |
| nci     | 11.681x | better     |
| xml     | 7.747x  | better     |
| samba   | 4.138x  | better     |
| webster | 3.214x  | better     |
| enwik9  | 3.037x  | comparable |
| mozilla | 2.710x  | comparable |
| dickens | 2.596x  | worse      |

All files BIT-PERFECT (MD5 verified).

## Build

    sudo apt-get install -y libzstd-dev g++
    git clone https://github.com/yasha1971-coder/aceapex
    cd aceapex && make

## Usage

    ./aceapex c --in myfile --out myfile.acpx --threads 8
    ./aceapex d --in myfile.acpx --out myfile_restored

## Honest Status

Research-grade. Encode is slow (307 MB/s) due to chain depth 32.
Designed for "compress once, decompress many times" workloads.
Not a drop-in replacement for zstd.

## License

MIT
