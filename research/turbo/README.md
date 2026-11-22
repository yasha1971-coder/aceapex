# TurboBench on ace-core (measurement only, nothing sent)

- 2026-11-05: TurboBench release v2026.11.05 (powturbo/TurboBench), `turbobench-linux-x86_64.tar.gz`,
  sha256 d5c2c2a1d76fe31f441fd3b055aed0770f1ef0a3f1237dd7c50a7ddae4edc06b; its own build of aceapex v2.6.1.
- Input: silesia.tar from DataCompression/corpus-collection (211 947 520 B, sha256 a667bac8…63eb2).
- Command (one run, load1 0.07 before, 1.03 after): `turbobench silesia.tar -U -v0 -eFAST/aceapex_fast,1,2,3,4`
  (the task said `-V0`; this build has no `-V`, verbosity is `-v#`). AMD EPYC 4344P, 12 min 16 s.
- Codec configuration: single-threaded (no `t#` given; `aceapex_fast` accepts `/t#` in this build, `-l1`); the process
  was not pinned in this run (user 12 m 0.8 s ~ real 12 m 16 s). Pinned runs: `direct/`.
- Result: `aceapex_fast 1` 61.57 %, compression 1 087 MB/s, decompression 12 279 MB/s, the fastest decompression in
  the table and on the Pareto front; +27.96 % over the next other codec by decompression speed, `misa77 1` (9 596 MB/s
  at 42.65 %); the row right below is its own level 2 (`aceapex_fast 2`, 10 597 MB/s at 54.13 %); `memcpy` 15 777 MB/s.
- Files: `silesia-2026-11-05.md` (the table as `-p4` prints it, format of TurboBench benchmark.md), `.tbb` (raw result),
  `.log` (console output, colour codes stripped).
