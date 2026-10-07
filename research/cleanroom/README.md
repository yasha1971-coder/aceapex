# Clean-room package for an independent refrel3 v1 decoder - how it was made (the package itself is not published)

Package: `~/cleanroom/refrel3_cleanroom_v1.zip`, 1 512 875 B, SHA-256 75ff3f609399e738d69312fafab5a17ec034883632ea9822bd8921db5221cc79
(60 files + SHA256SUMS; FORMAT.md byte-identical to research/refrel/FORMAT.md @ 5b6d5ce). Copies of its README_TASK.md,
EXPECTED.json and SHA256SUMS are here.

- Frozen tool: research/refrel @ 5b6d5ce via `git archive`, g++ 11.4.0 -O3 -march=x86-64-v3 -funroll-loops
  (binary SHA-256 b7d1842d340f32ddb2ae67fa4ebb67fdbdd1843378a46ab072c77bdc91b8a17a).
- `gen.py` (deterministic synthetic reference ~2 MB + reference_wrong + 6 assemblies), encoded by the frozen tool at
  Q 4096 / 16384 x with / without block hashes (24 archives); `opstat.cpp` (operation kinds per archive: literal / ref /
  self / rc - all present), `build_pkg.py` (package, fetch tables from the source FASTA), `add_hash_fixtures.py`
  (hash-targeted corrupt cases, block-swap search: 1 of 1 289 equal-length pairs decodes both streams), `blocks.cpp`
  (payload geometry), `verify_pkg.py` (frozen tool: 24/24 decodes, 1 200/1 200 fetches, 7/7 refusals).

Reproduce (from nothing, ~30 s): `bash research/cleanroom/repro.sh <new dir>` - frozen tool from 5b6d5ce (binary SHA-256
checked), data, 24 archives, package, hash fixtures, `add_swap_fixture.py` (blocks 64 / 67 of asmC.q4k), SHA256SUMS ==
the committed copy, frozen-tool verification 24/24, 1 200/1 200, 7/7, then the ZIP with the entry order, mtimes and
modes of `zip_entries_v1.tsv` (zip 3.0 -X, TZ=UTC). Run 2026-10-07: ZIP SHA-256 75ff3f60... 1 512 875 B - REPRODUCED.
