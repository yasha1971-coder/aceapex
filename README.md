# ACEAPEX

**A parallel LZ77 codec that resolves every back-reference to an absolute position at encode time — so any region decodes on the GPU without touching the rest of the file.**

Full device-resident GPU decode pipeline. Position-invariant random access on genomic data.

[![arXiv](https://img.shields.io/badge/arXiv-2606.04268-b31b1b.svg)](https://arxiv.org/abs/2606.04268)
[![arXiv](https://img.shields.io/badge/arXiv-2606.18900-b31b1b.svg)](https://arxiv.org/abs/2606.18900)
[![arXiv](https://img.shields.io/badge/arXiv-2606.24531-b31b1b.svg)](https://arxiv.org/abs/2606.24531)
[![arXiv](https://img.shields.io/badge/arXiv-2607.18541-b31b1b.svg)](https://arxiv.org/abs/2607.18541)
[![arXiv 2608.10188](https://img.shields.io/badge/arXiv-2608.10188-b31b1b.svg)](https://arxiv.org/abs/2608.10188)
[![Paper 5 DOI](https://img.shields.io/badge/Paper%205-10.5281%2Fzenodo.21874972-1682d4.svg)](https://doi.org/10.5281/zenodo.21874972)
[![lzbench](https://img.shields.io/badge/lzbench-2.3-blue.svg)](https://github.com/inikep/lzbench/releases/tag/v2.3)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/yasha1971-coder?style=social)](https://github.com/sponsors/yasha1971-coder)

---

## What this is

ACEAPEX is a research-grade LZ77 codec built around one design decision: **match search never leaves the current block**. That makes every block self-contained and independently decodable, which unlocks parallel decode on CPU and GPU and **position-invariant random access** — decoding an arbitrary region without decompressing the whole file. Inside a block, the encoder additionally redirects explicit references to their earlier originating position where the substitution validates byte for byte, shortening dependency chains; the rest is resolved by the decoder.

**Every published claim is answered with a number and a way to check it — see [CLAIMS.md](CLAIMS.md).**

It is not the densest compressor (see [Honest Status](#honest-status)). Its edge is **decode speed, region seek, and GPU residency** — useful when large static datasets are read far more often than written: genomic archives, columnar stores, GPU data-loading pipelines.

---

## Papers

- **Paper 1:** [ACEAPEX: Parallel LZ77 Decoding via Encode-Time Absolute Offset Resolution](https://arxiv.org/abs/2606.04268) — CPU scaling, GPU wavefront decoder, lzbench 2.3 integration.
- **Paper 2:** [Compressed-Resident Genomics: Full-Pipeline Device-Resident GPU LZ77 Decode with Position-Invariant Random Access](https://arxiv.org/abs/2606.18900) — Full GPU pipeline, genomic seek, 50 GB range-decode.
- **Paper 3:** [Unified Position-Invariant Random Access Through Two Compression Layers via Absolute-Offset Coordinates: A Bit-Perfect Device-Resident Proof](https://arxiv.org/abs/2606.24531) — Unified seek through entropy+match on GPU, 0.334 ms, bit-perfect, three-phase verified.
- **Paper 4:** [What Governs Decode Throughput in Absolute-Offset GPU LZ77? A Work-Granularity Mechanism and an Encode-Time Min-Match-Length Lever](https://arxiv.org/abs/2607.18541) — Decode throughput governed by work granularity, not occupancy; encode-time min-match-length lever improves ratio and throughput together on all eight datasets.

- **Paper 5:** [What Actually Serializes GPU LZ77 Decode: Three Decoders, Three Mechanisms, and an Encode-Time Lever That Removes the Last One](https://arxiv.org/abs/2608.10188) — Parse, not copy, holds 64–72% of device-resident decode; bounding chain depth moves latency by at most 2.8% and provably nothing at all where the file's own spike lives; self-overlapping matches are periodic fills, not chains, giving 2.75–8.42× on the match layer; the last sequential parse element is removed by the encoder for 0.540% of ratio.

Code archived on Zenodo: [Papers 1–3: 10.5281/zenodo.20729380](https://doi.org/10.5281/zenodo.20729380) · [Paper 4: 10.5281/zenodo.21316748](https://doi.org/10.5281/zenodo.21316748) · [Paper 5: 10.5281/zenodo.21874972](https://doi.org/10.5281/zenodo.21874972)

### Reproducing Paper 5

Every claim carries a level — **R** reproducible here, **M** measured but not bit-perfect, **E** estimated — and the script writes one JSON record per claim:

```bash
git clone https://github.com/yasha1971-coder/aceapex.git && cd aceapex
CHR1=/path/chr1.fa ENWIK9=/path/enwik9 ./reproduce_paper5.sh
```

A fresh clone of tag `paper5-v1` on a CPU-only host gives **17 pass, 0 fail, 6 skipped** (3 GPU claims need a CUDA device; 3 are the declared M and E entries). The recorded run ships as `results.json`.

---

## Core Idea

Standard LZ77 codecs face a tradeoff:

- Global context gives better ratio but forces sequential decode
- Independent blocks enable parallel decode but lose ratio

ACEAPEX takes the second branch and works on the price of it:

- **Encode:** match search is confined to the block, so a block never references outside itself; where it can be validated byte for byte, an explicit reference is additionally **redirected to the earlier originating position**, shortening the dependency chain inside the block
- **Decode:** block-parallel reconstruction — each block is self-contained and independently decodable

Two separate mechanisms, not one. Confining the search is what removes cross-block dependency and makes a block independently decodable; flattening only shortens dependency chains inside a block, and what remains is handled by the decoder — by wavefront ordering, or in closed form where a match is a periodic fill. The price is paid in ratio, and we state it: under an equal 16 KB independent-block constraint the match layer recovers about three quarters of what blocking costs (see [CLAIMS.md](CLAIMS.md)).

---

## lzbench 2.3

ACEAPEX (CPU) and `aceapex_cuda` (GPU) are included in the [official lzbench 2.3 release](https://github.com/inikep/lzbench/releases/tag/v2.3) — third-party validation by construction. To our knowledge, `aceapex_cuda` is the first GPU LZ77 decode path integrated into lzbench.

---

## Benchmarks

### CPU (lzbench 2.3, host-to-host, decompress MB/s)

| Dataset | CPU 1-thread | aceapex_cuda | CPU -T8 |
|---------|-------------|--------------|---------|
| FASTQ 1 GB (ERR194147) | 1,624 | 4,373* | 7,401 |
| enwik9 1 GB | 655 | 1,463 | 5,109 |
| silesia | 803 | 1,403 | 5,594 |

All results XXH3 bit-perfect verified.

*The FASTQ row was re-measured on ENA accession ERR194147 (md5 9af9ffaa0e15dba938408a711740e101);
the previously published figures (1,840 / 13,363 MB/s) came from a local sample with degenerate
quality strings. At ratio 3.98 versus zstd -3 at 3.96 on the same file, ACEAPEX -T8 decodes at
7,401 MB/s against zstd -3 at 2,026 MB/s: 3.65x faster at genuinely comparable ratio.
(*aceapex_cuda row not yet re-measured on the corrected file.)

### GPU — Full Device-Resident Pipeline (H100 SXM, 16 KB blocks, nvcomp-accelerated, bit-perfect)

| Dataset | Size | GB/s | Ratio |
|---------|------|------|-------|
| ~~FASTQ NA12878 | 1 GB | up to 260 | 11.19~~ | **WITHDRAWN 2026-07-12** |
| FASTQ ERR194147 | 5 GB | 168.9 | 3.31 |
| FASTQ ERR194147 | 50 GB† | 165.7 | 3.99 |

**Correction (2026-07-12):** the 1 GB "NA12878" row above is withdrawn. That local sample had
degenerate quality strings (2 distinct symbols instead of ~40), which inflated its ratio. The
ERR194147 rows are unaffected and were always measured on the real dataset. Re-measured on
ERR194147 (1 GB, md5 9af9ffaa0e15dba938408a711740e101): ratio 3.90 base / 3.97 tuned,
match-phase decode 142.6 / 178.6 GB/s, bit-perfect.

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
nvcc -O3 -std=c++17 -o aceapex_cuda lz/aceapex/cuda/aceapex_cuda_wrapper.cu -lpthread -lzstd
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
