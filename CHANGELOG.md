# Changelog

Software releases are tagged `vX.Y.Z` and follow `ACEAPEX_VERSION_*` in `src/aceapex.h`.
Tags `v2.0`, `v3.0`, `v4.0` and `paperN-v1` are paper artifacts, frozen (ADR-005, ADR-013).
Every number below is reproduced by `make test && ./verify.sh` on the tagged commit.

## Unreleased (main)

- Encoder: l1 is the default for DNA input (ADR-020): 8K-slot head table without a chain,
  matches >= 32 bytes, literal-run skipping, no offset flattening. chr1 68 127 499 -> 59 429 097 B
  (-12.77 %), encode 65 -> 444 MB/s per thread; T2T open profile -3.87 %. Format unchanged, every
  decoder reads it. Text keeps the chain matcher unless `AX_ENC=l1`; `AX_ENC=chain` restores the
  old bytes for DNA. Match length by 8-byte XOR/ctz (same bytes, encode ~10 % faster).
- Open profile CPU decode: bases unpacked by table, 16 KiB region on chr1 189 -> 157 us (C99).
- rANS token profile (ADR-018, `AX_TOK=rans`, chunk entry bit 62) and the open profile
  (ADR-019, `AX_PROFILE=open`: tokens rANS, literal chunks mode 2 open DNA pack / mode 3 open
  plain, spec §3.4): a genome archive without a single zstd frame, chr1 66 904 489 B against
  68 127 499 B default (-1.80 %). Opt-in; default bytes unchanged. Read by the C++, C99,
  Python and GPU decoders; GPU: k_rans, k_open_seq/cse/exc (no nvCOMP call on such an archive).
- C++ reader: literal chunk table validated against the stream, DNA pack (mode 1) framing
  checked, reserved literal flags rejected, varint shift bounded (found by fuzzing, 3000 runs).

## v2.1.0 — 2026-09-29

Format ACEPX2 (`version 2` in the header), specified in `docs/FORMAT_ACEPX2.md`. Archives
written by any 2.x build decode with this release; archives from before 2026-09-19
without the chunk field need `FSE_CHUNK` at decode time (spec §3.1, LEGACY).

Format and decoders
- Normative specification v1 of the container, block tokens, the four streams, the
  literal layouts (legacy 4-part, chunked, tagged: zstd or DNA pack), regions,
  fail-closed rules and versioning. Conformance set of 14 seeded archives with
  sha256 manifest (`verify/fixtures/conf`, `scripts/make_fixtures.py`).
- FSE streams are self-describing: chunk size in bits 48..62 of the first word (since
  2026-09-19); an empty input is a valid archive of one 68-byte header (ADR-011).
- Second decoder: `c/aceapex_decode.c`, C99, libzstd only, same names and error codes
  as `aceapex.h`; stateless calls plus a persistent handle (`aceapex_dec_open/region/
  ranges/close`) with per-stream `ZSTD_DCtx` and a 4-chunk cache (ADR-009, ADR-012).
  Fuzzed 2400 runs under ASan/UBSan; gcc/clang `-Wall -Wextra -pedantic` clean; block
  table read with byte copies (4-byte aligned header, ARM-safe).
- Cross-version fixtures: a 4 MiB chr1 slice encoded on libzstd 1.4.8 and 1.5.5 decodes
  on either, and the encoder reproduces the fixture bytes on the same libzstd line
  (ADR-008). Archive bytes do not depend on thread count or CPU architecture
  (x86-64 == aarch64 == armv7).

Platforms and bindings
- ARM: `scripts/arm_test.sh` cross-builds both decoders and the CLI for aarch64 and
  armv7 and runs every fixture under qemu-user; CI job `arm`.
- Python package `python/` (`pip install ./python`): `aceapex.open(path).read /
  ranges / decompress` over the C decoder; `aceapex.torch` datasets (`Windows`,
  `RandomWindows`, `TiledWindows`) that decode each block once per batch and survive
  `DataLoader` workers. Region read through Python: 135 us (64 MB DNA archive, 16 KiB).
- GPU: `aceapex_gpu.cu` decodes an archive as written in one process (nvCOMP batched zstd
  into the stream buffers, DNA unpack kernels, v7-RA match kernel; parser width probed
  at run time). Tesla T4, chr1: 27.8 ms on device, 33.4 ms with host-to-device.
  `gpu_zstd_batch.cu` is the entropy-layer harness. Requires nvCOMP 5.x (closed
  source); the CPU-entropy path (`aceapex_cuda` in lzbench) stays fully open.

Judge
- `make test` runs the HEAD judge without a corpus (fixtures only) and with one;
  claims are pass / fail / declared / skipped, never silently green. Fixed on foreign
  hosts this month: missing corpus reported as fail, symlinked corpus, `.gitignore`
  swallowing fixtures and the Python package.

Measured on ace-core (AMD EPYC 4344P, libzstd 1.4.8) unless stated: encode chr1
8 threads 0.94 s (270 MB/s, RSS 0.87 GB); C decoder full decode of a 64 MB DNA archive 0.245 s (261 MB/s).

## v1.0.1 — 2026-07-30 (lzbench line)

Format 1 as integrated in lzbench 2.3/2.4 (`lz/aceapex`): no DNA transform, no chunked
literals. Fixes landed upstream: threads passed to decompress, alignment-safe loads
(32-bit ARM), four small-input bugs, 64-bit hash positions, inputs < 768 bytes,
double-free on empty streams (Mark Zhuang). Superseded by 2.1.0 for new integrations.

## v1.0.0 — 2026-05-18

First release: parallel block LZ77 with absolute back-references, wall-clock timing,
lzbench 2.3 integration (PR #276).
