# Decode Mechanism: What Governs Throughput

Reproduction material for the mechanism half of the match-length work: the claim that
decode throughput in this codec is a function of **average match length** (work
granularity), and not of occupancy, parse cost, address locality, or launch parallelism.

The practical consequence — an encoder threshold that improves ratio *and* throughput
together — lives in [`../match-threshold/`](../match-threshold/). Read that one for the
result; read this one for why it works.

## The three tools

| tool | what it shows | needs |
|---|---|---|
| `match_length_curve.cu` | throughput as a function of match length, in isolation | H100-class GPU |
| `match_histogram.cpp` | where real data sits on that curve | CPU only |
| `offset_entropy.cpp` | why short matches also cost ratio | CPU only |

```bash
nvcc -O3 -arch=sm_90 -o match_length_curve match_length_curve.cu
g++  -O3 -march=native -std=c++17 -o match_histogram match_histogram.cpp
g++  -O3 -std=c++17 -o offset_entropy offset_entropy.cpp

./match_length_curve                                   # the curve
./match_histogram  enwik9 256000000                    # where enwik9 sits on it
./offset_entropy   NA12878.fastq 256000000             # why the threshold pays
```

## What we measured (H100 80GB, CUDA 12.4)

**The curve.** Output size held constant at 1 GB; only the average match length varies:

| avg match length | 32 | 64 | 128 | 256 | 512 | 1024 |
|---|---:|---:|---:|---:|---:|---:|
| GB/s | 212 | 417 | 606 | 693 | 737 | 741 |

A 3.5× span. The reason is structural: a cooperative group is 32 lanes wide, so a 32-byte
match gives each lane one byte and a shorter match leaves most of them idle.

**Where real data sits.** Greedy hash factorization, 256 MB prefixes:

| corpus | matches | coverage | mean length | below 32 bytes |
|---|---:|---:|---:|---:|
| enwik9 | 32.5 M | 82.8% | 6.5 | 99.1% |
| FASTQ (NA12878) | 11.9 M | 93.0% | 20.0 | 84.8% |

Real factorizations sit at the low, steep end. That is the whole story: throughput is not
capped by the hardware here, it is capped by how much work each match hands the warp.

**Why the threshold also helps ratio.** On FASTQ at `min_len=4`, the offset stream is ~66%
of the compressed bytes. A short match to a far, near-random offset spends more bits
encoding that offset than it saves in replaced literals. Raising the minimum length deletes
exactly those matches, so offset entropy falls faster than literal count rises.

## Hypotheses we rejected

Each was tested against a control before we accepted work-granularity:

| hypothesis | control | outcome |
|---|---|---|
| compute / parse bound | feed the kernel pre-parsed triplets | 212 GB/s ≈ real 221 → **rejected** |
| occupancy bound | `__launch_bounds__(128,16)`: regs 39→32, blocks 12→16 | *slower* (register spill): 221→202, 181→155 → **rejected** |
| address scatter (cold gather) | sorted vs. scattered source addresses | identical, 212.5 both → **rejected** |
| launch parallelism | two concurrent decode streams | 90.9 + 61.6 = 152 < 220 single → **rejected** |
| **work granularity** | throughput vs. average match length | **monotone, 3.5× span → accepted** |

`match_length_curve.cu` is the last row. The rejected controls are single-line variants of
it (drop the scatter in the source index; add `__launch_bounds__`; launch two streams) and
are quick to re-derive from it.

## Effective workload (Table 1 of the paper)

Throughput is a function of concurrent lanes, `lanes = G × block_count`, rather than of
block size or cooperation width separately — three different `(G, block_size)` settings at
131 K lanes all land at 170–183 GB/s; below ~32 K lanes the device starves, above ~1 M it
saturates. Reproducing this grid requires the full pipeline binary (`e2e_pipe_tile`), not
just these standalone tools: encode with `ACEAPEX_BS=<block_size>`, then decode with
cooperation width `G`, and record GB/s across the grid.

Occupancy in the paper is computed analytically with
`cudaOccupancyMaxActiveBlocksPerMultiprocessor` (39 registers → 12 resident blocks/SM →
1584 total), not with profiler counters — Nsight counters are restricted on the cloud host
we used (`ERR_NVGPUCTRPERM`). The mechanism is established by controlled ablation instead.

## Honest scope

- The curve is a **synthetic copy kernel**: it isolates match-copy from parsing on purpose.
  The end-to-end numbers in the paper come from the real pipeline, not from this tool.
- `offset_entropy.cpp` models the entropy stage (order-0, per-stream). The shipping encoder
  is stronger — dist-dependent thresholds, repeat offsets, depth factorization — so its
  absolute ratios are higher. This tool shows the *mechanism*, not the shipped ratio.
- The plateaus (≈217 GB/s on enwik9, ≈377 on FASTQ at their tuned match lengths) are real
  bandwidth limits at that granularity. Raising the average match length moves the
  operating point up the curve; it does not raise the ceiling.
