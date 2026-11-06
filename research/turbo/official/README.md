# TurboBench official results (powturbo/TurboBench benchmark.md), as published

- 2026-11-06 18:39 UTC, commit 4d3ea5c (`Update benchmark.md from build v2026.11.06.164`): the first table after
  `aceapex_fast,1` joined the FAST group (powturbo f048494, 2b2c5bf; issue #65). benchmark.md of this build has
  only macos-aarch64 sections (2: the FAST table and another group without aceapex); linux-x86_64, linux-aarch64,
  linux-riscv64 are not in it. Windows does not produce a table.
- macos-aarch64 (Apple M1 (Virtual), 2026.11.06 17:31), FAST, silesia.tar: `aceapex_fast 1` 61.57 %, compression 825.00,
  decompression 12 174.59 MB/s, Pareto (bold), rank 3; the fastest decompression in the table after memcpy
  (27 825.59); next codec misa77 1 9 474.21 MB/s (+28.5 %), misa77 0 9 040.20.
- 2026-11-06 21:39 UTC, commit 2302e86 (`Update benchmark.md from build v2026.11.06.165`); FAST now lists
  `aceapex-fast,1,8` (powturbo 63ac658: `aceapex_fast` -> `aceapex-fast`; 1907d8a: levels 1,8). Sections: linux-aarch64 x2,
  linux-riscv64, macos-aarch64 x2, windows-x86_64 x2; no linux-x86_64 section. Rows with aceapex-fast 1 (silesia.tar, 61.57 %):
  | platform | CPU line | C MB/s | D MB/s | Pareto | rank | fastest other codec, D MB/s |
  |---|---|---:|---:|---|---|---|
  | macos-aarch64 | Apple M1 (Virtual) | 743.97 | 11 131.70 | yes | 3 | misa77 1, 8 727.15 (aceapex-fast 1 +27.6 %) |
  | linux-aarch64 | Unknown Linux CPU | 625.73 | 4 911.42 | no | 5 | misa77 0, 5 085.24 (aceapex-fast 1 -3.4 %) |
  linux-riscv64: 16 rows, no aceapex-fast row. windows-x86_64: aceapex is not built into the Windows binary. Level 8 does
  not appear in any section of this build. Files: `<platform>-FAST-v2026.11.06.165.md`, `benchmark-2302e86-v2026.11.06.165.md`.
- Files: `benchmark-4d3ea5c-v2026.11.06.164.md` (the whole benchmark.md at that commit), `macos-aarch64-FAST-v2026.11.06.164.md`
  (its FAST section). Nothing sent; measurement by powturbo's CI.
