# ACEAPEX GPU full-pipeline decode (TILE-ANS) — D1 device-resident

Full device-resident decode: ANS entropy (DietGPU) + LZ match kernel, whole file, bit-perfect.
Entropy tile granularity DECOUPLED from LZ block_size (ANS on fixed 64KB tiles cut across
flat streams; match kernel keeps its own block_size).

## Measured result (PAPER5, 2026-07-20, pod H100 80GB, CUDA 12.4)
- **D1-dense: 200.4 GB/s** full-pipeline (+13% over fused 177.3 GB/s)
- data: NA12878_REAL.fastq md5 9af9ffaa (honest), tuned streams.bin ratio 3.970
- bit-perfect: FNV 513444748a087502
- PARSE WALL (second bottleneck, honest): ANS+parse 2.664ms / copy 2.694ms (49.7%/50.3%)
  -> command-parse is HALF of decode time.

## Files
- e2e_dense_HOST.cu — host driver, full-pipeline TILE-ANS (main D1 binary)
- d2p_dense_v4_282.cuh — dense two-core decode kernel (the +13% version)
- d2p_kernel.cuh — kernel helpers
- e2e_pipe_tile.cu — earlier tile-pipe variant
- gpu_hash_finder.cu — GPU match finder (encode side)
- nsight_sweep.sh — Nsight occupancy/L2/DRAM sweep by block_size
- silesia_all.sh — throughput+FNV over all 12 Silesia files

## Build (H100, sm_90)
nvcc -O3 -arch=sm_90 -I/path/to/dietgpu -o e2e_dense e2e_dense_HOST.cu /path/to/dietgpu/dietgpu/ans/GpuANSDecode.cu -lgpu_ans -ldietgpu_utils
Requires DietGPU (github.com/facebookresearch/dietgpu) built for libgpu_ans.

## Reproduce
Clone this repo at the recorded commit, get NA12878 by md5 9af9ffaa, encode to streams.bin,
run e2e_dense on it, verify FNV. See PAPER5_DENSE in private context for exact params.
