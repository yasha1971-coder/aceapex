# TurboBench official results (powturbo/TurboBench benchmark.md), as published

- 2026-11-06 18:39 UTC, commit 4d3ea5c (`Update benchmark.md from build v2026.11.06.164`): the first table after
  `aceapex_fast,1` joined the FAST group (powturbo f048494, 2b2c5bf; issue #65). benchmark.md of this build has
  only macos-aarch64 sections (2: the FAST table and another group without aceapex); linux-x86_64, linux-aarch64,
  linux-riscv64 are not in it. Windows does not produce a table.
- macos-aarch64 (Apple M1 (Virtual), 2026.11.06 17:31), FAST, silesia.tar: `aceapex_fast 1` 61.57 %, compression 825.00,
  decompression 12 174.59 MB/s, Pareto (bold), rank 3; the fastest decompression in the table after memcpy
  (27 825.59); next codec misa77 1 9 474.21 MB/s (+28.5 %), misa77 0 9 040.20.
- Files: `benchmark-4d3ea5c-v2026.11.06.164.md` (the whole benchmark.md at that commit), `macos-aarch64-FAST-v2026.11.06.164.md`
  (its FAST section). Nothing sent; measurement by powturbo's CI.
