# spec_val — reader rules made one rule in 2.6.7 (SPEC-VAL-1, FORMAT_ACEPX2 8)

One archive per rule (`gen.py`), each otherwise accepted by the readers of 2.6.6:

| archive | rule | refused since 2.6.7 by |
|---|---|---|
| `empty_v7.aet` | empty archive of version 7 (D1) | C++ (C99 and GPU before) |
| `empty_bs128m.aet` | empty archive with block_size 128 MiB (D2) | C++ (C99 and GPU before) |
| `lit_ch32k.aet` | chunked literals with CH < 65536 (D7) | C++, C99, GPU |
| `lit_ch65636.aet` | CH not a multiple of 4096 (D6) | C++ in memory, C99, GPU (the C++ streaming decoder before) |
| `zstd_multi.aet` | a literal chunk of two zstd frames (D8) | C++, C99 (GPU before) |
| `varint_cut.aet` | the last offset varint cut by its slice (D9) | C++, C99 (GPU kernel before) |
| `dna_noexc_h3.aet` | DNA pack with nexc = 0 and a gap frame (D18) | C++, C99, GPU |
| `trunc100.aet` | a 0-byte region read of a truncated archive (D13) | C99 (C++ before) |
| `bs128m.aet`, `tokch17m.aet` | block_size 128 MiB; token chunk 16 MiB + 4 KiB (D3) | GPU (CPU since 2.6.4) |

`dna_noexc_intact.aet`: 70 000 random ACGT (seed 20261128) compressed by `aceapex c --level 1 --threads 1` of this tree.

Tests: `spec_val_test.cpp` (C++, 6 entry points), `spec_val_c99.c` (C99 = the Python package),
`gpu_plan_267_test.cpp` (GPU host plan). Every test has one negative control: the macros named at its top together give
the reader of 2.6.6, which decodes / plans the archives with the original bytes.
Untested by an archive: NW > 65535 (needs a literal stream above 4 GiB), the token slice bound and the LEGACY FSE_CHUNK
rounding of the GPU plan (D3 / D11; tuning builds).
