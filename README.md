# ACEAPEX

**A parallel LZ77 codec that resolves every back-reference to an absolute position at encode time — so any region decodes on the GPU without touching the rest of the file.**

Full device-resident GPU decode pipeline. Position-invariant random access on genomic data.

[![arXiv](https://img.shields.io/badge/arXiv-2606.04268-b31b1b.svg)](https://arxiv.org/abs/2606.04268)
[![arXiv](https://img.shields.io/badge/arXiv-2606.18900-b31b1b.svg)](https://arxiv.org/abs/2606.18900)
[![lzbench](https://img.shields.io/badge/lzbench-2.3-blue.svg)](https://github.com/inikep/lzbench/releases/tag/v2.3)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/yasha1971-coder?style=social)](https://github.com/sponsors/yasha1971-coder)

---

## What this is

ACEAPEX is a research-grade LZ77 codec built around one design decision: back-references are stored as **absolute positions** in the decompressed output, not relative distances in a sliding window. That single choice makes every block self-contained, which unlocks parallel decode on CPU and GPU and **position-invariant random access** — decoding an arbitrary region without decompressing the whole file.

It is not the densest compressor (see [Honest Status](#honest-status)). Its edge is **decode speed, region seek, and GPU residency** — useful when large static datasets are read far more often than written: genomic archives, columnar stores, GPU data-loading pipelines.

---

## Papers

- **Paper 1:** [ACEAPEX: Parallel LZ77 Decoding via Encode-Time Absolute Offset Resolution](https://arxiv.org/abs/2606.04268) — CPU scaling, GPU wavefront decoder, lzbench 2.3 integration.
- **Paper 2:** [Compressed-Resident Genomics: Full-Pipeline Device-Resident GPU LZ77 Decode with Position-Invariant Random Access](https://arxiv.org/abs/2606.18900) — Full GPU pipeline, genomic seek, 50 GB range-decode.

Code archived on Zenodo: [DOI 10.5281/zenodo.20729380](https://doi.org/10.5281/zenodo.20729380)

---

## Core Idea

Standard LZ77 codecs face a tradeoff:

- Global context gives better ratio but forces sequential decode
- Independent blocks enable parallel decode but lose ratio

ACEAPEX separates these responsibilities instead of trading between them:

- **Encode:** global analysis, full match search across the entire input — every back-reference resolved to an **absolute position** in the decompressed output
- **Decode:** block-parallel reconstruction — each block is self-contained and independently decodable

This is *global analysis, local decode*. The same property enables position-invariant random access: because every block carries absolute offsets, any region decodes without touching the rest of the file.

---

## lzbench 2.3

ACEAPEX (CPU) and `aceapex_cuda` (GPU) are included in the [official lzbench 2.3 release](https://github.com/inikep/lzbench/releases/tag/v2.3) — third-party validation by construction. To our knowledge, `aceapex_cuda` is the first GPU LZ77 decode path integrated into lzbench.

---

## Benchmarks

### CPU (lzbench 2.3, host-to-host, decompress MB/s)

| Dataset | CPU 1-thread | aceapex_cuda | CPU -T8 |
|---------|-------------|--------------|---------|
| FASTQ 1 GB | 1,840 | 4,373 | 13,363 |
| enwik9 1 GB | 655 | 1,463 | 5,109 |
| silesia | 803 | 1,403 | 5,594 |

All results XXH3 bit-perfect verified.

### GPU — Full Device-Resident Pipeline (H100 SXM, 16 KB blocks, nvcomp-accelerated, bit-perfect)

| Dataset | Size | GB/s | Ratio |
|---------|------|------|-------|
| FASTQ NA12878 | 1 GB | up to 260 | 11.19 |
| FASTQ ERR194147 | 5 GB | 168.9 | 3.31 |
| FASTQ ERR194147 | 50 GB† | 165.7 | 3.99 |

†Range-decode (output size decoupled from VRAM). H2D/D2H excluded from timer: target consumer is GPU-resident.

**Two GPU modes:**
- **Mode 1** (nvcomp-free, in lzbench 2.3, ARM-portable): entropy on CPU, match on GPU — ships today, fully open.
- **Mode 2** (nvcomp-accelerated, device-resident): entropy + match both on GPU — performance ceiling, requires proprietary nvcomp.

### Random Access (5 GB genome, 16 KB blocks)

| Operation | Time | Note |
|-----------|------|------|
| Full decode | 29.71 ms | 168 GB/s baseline |
| Seek 1 block (16 KB) | 0.365 ms | point |
| Seek 100 blocks (1.6 MB) | 0.394 ms | region |

Single-block seek is **81× faster** than full decode. Latency is size-independent — it is dominated by fixed kernel-launch overhead, so seeking 1 block and 100 blocks cost almost the same.

**vs samtools faidx:** ACEAPEX resident seek **0.362 ms** vs samtools warm **2.3 ms** (~6× faster). Read-to-block index **40 MB** vs **.fai 250 MB** (6.3× smaller).

> Boundary: this is read-level access (read id → block), not chr:pos coordinate access. Raw FASTQ precedes alignment; chr:pos belongs to BAM and is future work.

### DietGPU ANS (H100, open-source, standalone)

Meta's open DietGPU ANS: encode **364.9 GB/s**, decode **592.5 GB/s**, bit-perfect. Demonstrates that a fully open replacement for the proprietary entropy stage is viable. Full integration into the ACEAPEX pipeline is future work.

---

## Honest Status

- **Ratio:** ACEAPEX is not best-in-class on ratio. zstd-19 is 1.2–1.55× denser on FASTQ. The position is decode speed + seek + GPU residency at *comparable* ratio, not maximal compression.
- **Mode 2** depends on proprietary nvcomp (closed-source since v2.3). Only Mode 1 is fully open today.
- **Encode** is slow (50 GB at ~340 MB/s) — appropriate for encode-once/decode-many workloads.
- **Seek** is read-level, not chr:pos. Raw FASTQ precedes alignment.

---

## Key Properties

- Bit-perfect (XXH3-64 for CPU paths, FNV for GPU paths)
- Global-analysis encoding with block-local decode representation
- Parallel block decode — scales with cores and GPU warps
- Position-invariant random access — any block decodable independently
- Mode 1: CUDA runtime only, no external GPU libraries, ARM-portable
- C++17, libzstd for entropy (Mode 1)
- MIT-licensed, research-grade

---

## Build

**CPU (Mode 1):**
```bash
sudo apt-get install -y libzstd-dev g++
g++ -O3 -march=native -funroll-loops -std=c++17 \
    -o aceapex src/aceapex_main.cpp -lpthread -lzstd
```

**GPU (aceapex_cuda, Mode 1 — nvcomp-free):**
```bash
nvcc -O3 -std=c++17 -o aceapex_cuda src/aceapex_cuda.cu -lpthread -lzstd
```

---

## Usage

```bash
# Compress
./aceapex c --in myfile --out myfile.aet --threads 8

# Decompress
./aceapex d --in myfile.aet --out myfile_restored

# Benchmark (in-memory)
./aceapex t --in myfile --threads 8
```

---

## Documentation

See [BENCHMARK.md](BENCHMARK.md) for detailed benchmarks and [TECHNICAL_NOTE.md](TECHNICAL_NOTE.md) for design notes.

---

## License

MIT — see [LICENSE](LICENSE).

---

## Acknowledgements

Thanks to [inikep](https://github.com/inikep) for maintaining lzbench and reviewing the integration, tansy for code review, and the [encode.su](https://encode.su) community.
Research conducted in collaboration with Claude (Anthropic) as an AI research assistant.
