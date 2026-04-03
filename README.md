# ACEAPEX

High-throughput lossless compression.  
Global analysis at encode time. Parallel block decode at runtime.

## Key Result (enwik9, 1GB, AMD EPYC 4344P, 8 threads)

| Metric | Value |
|--------|-------|
| Ratio | 3.896x |
| Decode | **11609 MB/s** |
| Verification | SHA-256 bit-perfect |

**Note:** Encode speed was incorrectly measured in earlier versions.
The timer covered only the LZ77 pass, not the zstd entropy coding step.
Corrected benchmarks in progress.

## Head-to-Head — Decode Speed (enwik9, 8 threads)

| Codec | Ratio | Decode |
|-------|-------|--------|
| zstd -9 | 3.759x | 1429 MB/s |
| zstd -19 | 4.245x | 1420 MB/s |
| **ACEAPEX** | **3.896x** | **11609 MB/s** |

All results SHA-256 bit-perfect verified.

## Canterbury Corpus (bit-perfect)

| File | Ratio | Encode | Decode |
|------|-------|--------|--------|
| kennedy.xls | 14.69x | 1639 MB/s | 2588 MB/s |
| ptt5 | 10.20x | 1754 MB/s | 2816 MB/s |
| E.coli | 3.95x | 1344 MB/s | 4915 MB/s |
| bible.txt | 3.51x | 1089 MB/s | 4012 MB/s |
| alice29.txt | 2.77x | 280 MB/s | 507 MB/s |


## Core Idea

Standard LZ77 codecs face a tradeoff:
- Global context gives better ratio but requires sequential decode
- Independent blocks enable parallel decode but lose ratio

ACEAPEX separates these responsibilities:
- **Encode**: global analysis, full match search across entire input
- **Decode**: block-parallel reconstruction via precomputed per-block stream offsets

Cross-block LZ77 matches are resolved into block-local form at encode time.  
Decode-time back-references do not cross block boundaries.  
This is "global analysis, local decode" — not true global LZ77 decode dependency.

## Key Properties

- Bit-perfect (SHA-256 verified on every run)
- Global-analysis encoding with block-local decode representation
- Parallel block decode — scales with cores
- Single-file C++17, libzstd only
- Research-grade code, not a production library

## Download

| Platform | File | Size |
|----------|------|------|
| Linux x64 | [aceapex](aceapex) | ~42KB |
| Windows x64 | [aceapex.exe](aceapex.exe) | ~2MB |

Linux usage:
```bash
./aceapex.sh compress myfile.txt
./aceapex.sh decompress myfile.txt.aet
./aceapex.sh test myfile.txt
```

Windows usage:
```cmd
aceapex.exe c --in myfile.txt --out myfile.txt.aet --threads 8
aceapex.exe d --in myfile.txt.aet --out myfile.txt
aceapex.exe t --in myfile.txt --threads 8
```

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

## Status

Research-grade. No claims of universality.  
One data point on a tradeoff curve.

## License

MIT
