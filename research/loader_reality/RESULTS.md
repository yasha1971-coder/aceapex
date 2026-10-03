# loader_reality — does the window source matter for a training step? (Colab Blackwell, 2026-10-03)

Script: `run_colab.sh` -> `loader_reality.py`; log excerpt: `logs/colab-blackwell-2026-10-03-excerpt.txt`.
Card: RTX PRO 6000 Blackwell Server Edition, 95.0 GiB; torch 2.11.0+cu130, CUDA 13.0. Model: causal transformer,
98.4 M parameters, bf16 autocast, AdamW (fused), context 8192, one token per byte. Windows from T2T-CHM13v2.0.

## Step and window source

| batch | source | step, ms | getting the batch, ms | share of the step | tokens/s |
|---:|---|---:|---:|---:|---:|
| 8 | (a) raw bytes resident in VRAM | 320.0 | 0.059 | 0.02 % | 204 770 |
| 8 | (b) ACEAPEX open archive resident, decoded on the card | 320.8 | 0.655 | **0.20 %** | 204 315 |
| 8 | (c) pyfaidx DataLoader, 2 / 4 / 8 workers | 320.2 / 320.4 / 320.5 | 0.070 / 0.064 / 0.059 | 0.02 % | 204 676 / 204 550 / 204 477 |
| 32 | (a) raw in VRAM | 1531.7 | 0.112 | 0.01 % | 171 149 |
| 32 | (b) ACEAPEX in VRAM | 1534.1 | 0.821 | 0.05 % | 170 877 |
| 32 | (c) pyfaidx, 2 / 4 / 8 workers | 1534.4 / 1533.0 / 1533.9 | 0.134 / 0.121 / 0.124 | 0.01 % | 170 844 / 170 999 / 170 898 |

(a) and (b) byte-equal: 20 of 20 batches of 32 windows. Model alone: batch 8 319.4 ms / 205 176 tokens/s / peak 24.13
GiB; batch 32 1215.0 ms / 215 764 tokens/s / peak 92.03 GiB (no checkpointing). With the sources resident the batch-32
step is 1532-1534 ms - 26 % slower than alone, in every source alike: the card is near full (92 of 95 GiB), not
explained further here.

**Conclusion: getting the batch is at most 0.20 % of the step** (ACEAPEX decode at batch 8; 0.01-0.02 % for raw bytes
and pyfaidx). For a ~100 M model at context 8192 the window source does not change the step time; decoding on the
card does not speed up an epoch. A CPU DataLoader with 2 workers already keeps up.

## Capacity beside the model (assemblies of ~3.07 GB FASTA)

| card | batch | model peak, GiB | left, GiB | raw FASTA | 2 bits | ACEAPEX open |
|---|---:|---:|---:|---:|---:|---:|
| 80 GiB | 8 | 24.13 | 55.87 | 19 | 78 | 71 |
| 96 GiB | 8 | 24.13 | 71.87 | 25 | 100 | 93 |
| 80 / 96 GiB | 32 | 92.03 | -12.03 / 3.97 | - / 1 | - / 5 | - / - |

Per assembly (HG00438.1 / .2): FASTA 3.068 GB, 2 bits 0.767 GB, open 0.776 GB. **Open is not better than 2 bits for
capacity** (0.776 against 0.767 GB): its ratio on a genome alone is ~4, the 2-bit pack's is 4 by construction. What
changes capacity is a reference: research/refrel (branch `refrel`) stores an HPRC assembly in 19.5 MB on the card
beside the decoded T2T - 2 912 assemblies in the same 55.87 GiB at batch 8.
