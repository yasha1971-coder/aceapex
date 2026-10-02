# Changelog

Software releases are tagged `vX.Y.Z` and follow `ACEAPEX_VERSION_*` in `src/aceapex.h`.
Tags `v2.0`, `v3.0`, `v4.0` and `paperN-v1` are paper artifacts, frozen (ADR-005, ADR-013).
Every number below is reproduced by `make test && ./verify.sh` on the tagged commit.

## v2.3.0 — DRAFT (not released; numbers marked [H100] are filled by the next H100 run)

Format ACEPX2 unchanged; archive bytes unchanged for a given libzstd (every change below is a decoder change;
encoder output byte-identical, checked by the conformance fixtures and the speed gate's pinned archive sizes).
Version macros are bumped at tag time, not in this draft.

- **GPU library with a C ABI** (`src/aceapex_gpu.h`, `libaceapex_gpu.so.1`, `docs/GPU_API.md`): host plan +
  async decode without allocation or synchronisation, range decode by coordinate, fail-closed status bits,
  `ACEAPEX_GPU_VERIFY_XXH3` (hash of the output on the device), `ACEAPEX_GPU_VALIDATE_ZSTD` (every zstd frame
  through libzstd on the host first: nvCOMP 5.3.0.16 does not return on some corrupt frames, repro in
  `verify/repro/nvcomp_zstd_hang/`). Frozen for 2.3: `plan_create(h, n, uint64_t flags)` (unknown bits ->
  `E_ARGS`), `ACEAPEX_GPU_API_VERSION` 20300 + `aceapex_gpu_version()`; later versions only add.
- **GPU fail-closed**: every kernel loop bounded (step limit -> `STATUS_LIMIT`), varints <= 5 bytes, 64-bit sizes in
  the descriptors; claims `head_gpu_flip_emu`, `head_gpu_zstd_validate`, `head_gpu_abi`.
- **GPU decode faster** (Blackwell, on-device, same archives): T2T open 27.14 -> 19.58 ms (library), chr1 open
  2.83 -> 1.93 ms. Steps: rANS refill from a register window (AX_OPEN_SEQ, seq -23 %), exception positions in the
  case-run kernel and the bytes in the bases store (AX_OPEN_EXC), the block's run ends in shared memory
  (AX_OPEN_SHB, T2T unpack -17 %), 16-byte stores (AX_VEC). AX_GPU_TILE (literals of a block built in shared
  memory, no literal stream): in the code, off by default until measured [H100].
- **CPU decode** (ace-core, EPYC 4344P 8 cores / 16 threads, median of 5, bit-perfect): T2T open 8 threads
  1.039 -> 0.229 s, all threads 0.955 -> 0.183 s (before = 374e4f0, 2.2.1 + AVX2 rANS); chr1 default 8 threads 0.094 -> 0.026 s; silesia default
  8 threads 0.074 -> 0.038 s. Steps: AVX2 rANS (AX_RANS_SIMD; open profile 1 thread x1.8-x2.4), compressed
  streams read in place, transparent huge pages + parallel prefault, literal tiles in L2 instead of a literal
  stream (AX_LIT_TILE), non-temporal output (AX_NT), default budget = physical cores (all threads >= 1 GiB).
  AVX-512 rANS (AX_RANS_SIMD=512) kept, not default: no gain on Zen 4.
- **Streaming decode (CPU)**: `aceapex_decompress_stream(read cb, write cb, threads, flags)` on the tile path, memory
  O(threads x tile), not O(archive): T2T open 16 threads 14.2 GB/s at 34.9 MB RSS, 1 thread 1.8 GB/s at 7 MB
  (`results/stream-2026-10-02.log`); `ACEAPEX_STREAM_VERIFY` checks XXH3 against the header; CLI `d --out -` / `-c`
  to stdout (archives without the chunked literal layout fall back to the whole-file decoder). Claim `head_stream`.
- **Thread start**: the encoder's two thread_local arrays (8 MiB of TLS, zeroed in every new thread of a process
  linking the library, decode threads included) are heap buffers on first use: T2T open full decode, all threads,
  0.202 -> 0.183 s.
- **GPU outputs larger than the card**: block-range plans `aceapex_gpu_plan_create_blocks(h, n, b0, b1, flags)` +
  `aceapex_gpu_plan_input_window` (ABI additions): streams restricted to the blocks' chunks, temp and output sized
  for the batch; `scripts/gpu_stream.cu` decodes batches sized from the free memory, two in flight (decode / D2H),
  XXH3 on the host. CPU judge: 121 batches through the plan emulator == original [H100: speed].
- open: token chunk 16 KiB by default; region decode CPU p50 -21 % (T2T) / -37 % (chr1), p99 -35 % / -26 %; +452 B on T2T
  (+8 186 B on chr1); full decode unchanged within 2.3 %; old archives decode unchanged (`results/open-tok16-2026-10-02.log`).
- Region decode: the literal chunk table is no longer walked one entry at a time per call (check summed in runs, the
  first chunk's body found by a straight sum, only the region's chunks visited); `aceapex faidx` copies bases in runs.
  T2T 5000-base regions, 1 thread, p50: in process 92 -> 50 us (htslib `faidx_fetch_seq64` 102-104 us), `faidx -r`
  119 -> 71 us per region (samtools -r 103-108 us). Decoder change only (`results/faidx-2026-10-03.log`).
- **Literal chunk cap lifted** (65 535 -> 2^30 chunks): a DNA input above ~4 GiB of literals keeps the chunked layout
  and the DNA transform - HPRC x 3 in one file 2 705 974 278 -> 2 140 557 191 B (ratio 3.36 -> 4.24) - and streams.
  Archive bytes change only for such inputs; the 2.2.2 C++ and C99 decoders read them (`results/litcap-2026-10-02.log`).
- **Measurement tools** (no format change; `results/dep-range-2026-10-01.log`, `results/reality-2026-10-02.log`,
  `results/pangenome-2026-10-02.log`): match reach, bits by region class, approximate-repeat estimate, block cost
  and thread tail (`AX_BLOCK_TIMES`, `AX_SCHED_COST`), and the AX_REFSEG pangenome prototype (`scripts/refseg.cpp`,
  its own container). Encoder knobs for them in tuning builds only: `AX_MAXDIST`, `AX_HASH12`; default bytes unchanged.
- **Speed gates**: `make perf-gate` (`results/baseline_ace-core.tsv`, > 5 % slower fails), per-card GPU baselines
  checked in the run's SUMMARY.
- **One GPU run script**: `scripts/gpu_run.sh` (RunPod / Colab / any host; corpus ladder chr1 -> T2T -> GRCh38 ->
  HPRC with checksums; outputs larger than the card in windows, `scripts/gpu_stream.cu`).
- Build: `make ZSTD_SRC=<zstd 1.5.x tree>` links zstd statically (1.5.x: chr1 default 1 thread -16 % against the
  system 1.4.8).

## v2.2.2 — 2026-10-01

DOI: [10.5281/zenodo.23090998](https://doi.org/10.5281/zenodo.23090998)

Archive bytes identical to 2.2.1 (the defaults are untouched; checked by the judge and on silesia/xml).

- **The library no longer reads the environment** (lzbench #336, Przemysław Skibiński). The 16 tuning variables
  (`ACEAPEX_BS`, `ACEAPEX_DUMP`, `AX_ATT`, `AX_ENC`, `AX_HLOG`, `AX_LIT`, `AX_MINL`, `AX_NOFLAT`, `AX_PROFILE`, `AX_SKIP`,
  `AX_TOK`, `FSE_CHUNK`, `LIT_CHUNK`, `LIT_LANES`, `LIT_LANES_DEC`, `LIT_LEVEL`) are read through one `ax_getenv()`
  (`src/ax_env.h`) that returns NULL unless the build defines `ACEAPEX_ENV_TUNING`. The library is built without it
  (lzbench, TurboBench, any program linking it); the CLI (`ACEAPEX_CLI`), the C99 reader CLI `axdec`, the Python reader
  and the repository's tools are built with it. On silesia/xml at level 1, one thread, with lzbench's zstd 1.5.7, five
  settings of these variables gave 724378 / 853990 / 812809 / 734621 / 829935 bytes in 2.2.1 and give 724378 in all five
  now. `LIT_LANES_DEC` no longer starts decode threads when the caller asked for one (strace: 7 clones before, 0 now).
  Claim `head_env_ignored`.

## v2.2.1 — 2026-09-30

DOI: [10.5281/zenodo.23070077](https://doi.org/10.5281/zenodo.23070077)

Archive bytes identical to 2.2.0 (compared on silesia, enwik8 and chr1, levels 1-3, 1 and 8 threads,
default / open / interactive profiles: 54 of 54 byte-identical; fixtures unchanged).

- fixed: the encoder did not keep to its thread budget. With threads=1 its entropy stage still ran the
  three token streams on three threads and the literal lanes on up to the CPU count (lzbench `-I1`:
  146 % CPU; level 3 on silesia 304 MB/s unpinned against 195 MB/s on one core). Now the literal lanes,
  the token streams and the LZ workers share the call's budget, the caller being one of the workers:
  threads=1 starts no thread at all. Claim `head_enc_threads` (24 round-trips at threads=1 over four
  profiles, DNA and text, levels 1-3, compress + decompress + region: 0 threads started). Multi-threaded
  encoding unchanged (silesia -2, 8 threads, 0.77 s against 0.78 s).
- The single-thread compression figures published with 2.2.0 for lzbench (level 1 96.1, level 2 71.6,
  level 3 305 MB/s on silesia) overstated one core for the same reason; on one core they are 86.1 / 66.2 /
  195 MB/s. Decompression was not affected (one thread at threads=1 since 2.1.0).

## v2.2.0 — 2026-09-30

DOI: [10.5281/zenodo.23061934](https://doi.org/10.5281/zenodo.23061934)

Format ACEPX2 unchanged (`version 2`). Archives of the default profile written by 2.2.0 (the l1
encoder included) decode with 2.1.0; archives of the rANS-token and open profiles (ADR-018/019)
need 2.2.0 (2.1.0 does not know chunk entry bit 62 or literal modes 2/3).

Fixed
- fixed: concurrent API calls could return wrong output; affected 2.1.0 (the aceapex copy in
  lzbench 2.4, "1.0.1", is not affected). The block size, the decode error flag and the DNA hint
  were process globals shared by calls running at once (lzbench `-T`, servers). Two threads over
  lzbench's source tree (4569 files): 2.1.0 returned wrong bytes for 22; 1.0.1 (lzbench copy) 0 in
  3 runs; 2.2.0 0. Now per call (thread-local, inherited by the call's worker threads); claim
  `head_api_concurrent` (4 threads, 96 jobs, full and region decode: 0 failures, 29-32 before).
- fixed: the library did not build with MinGW (sysconf, posix_memalign); the CLI stays POSIX (mmap).
- fixed: an empty stream (zeros, tiny inputs) no longer depends on malloc(0) returning non-NULL.

Platforms (release gate, `scripts/cross_matrix.sh`, libzstd 1.5.5 built per target): x86-64, x86-32
(i686), ARM32 (armhf), ARM64 and PPC64LE under qemu-user: 44/44 conformance decodes (C99 + CLI),
chr1 slice fixtures 4/4, chain re-encode == fixture, l1 encode == x86-64 bytes (3 profiles),
api_roundtrip 468/468, api_concurrent 0 failed on each; MinGW x86-64: library, C99 decoder and API
programs build (no Windows runner).

Encoder
- l1 is the default encoder for DNA input (ADR-020): an 8K-slot head table without a chain, window =
  the block, matches >= 32 bytes, literal-run skipping, no offset flattening; the short repeats are
  left to the literal coder. chr1 default 68 127 499 -> 59 429 097 B (-12.77 %), encode 65 -> 444 MB/s
  per thread (ace-core, EPYC 4344P). Text and other input keep the chain matcher; `AX_ENC=l1` /
  `AX_ENC=chain` or API/CLI level 3 choose explicitly. Judge claim `head_l1_dna_default` (5 profiles).
- Match length by 8-byte XOR/ctz: same bytes, chain encode ~10 % faster.

Zstd-free genome path (ADR-018, ADR-019)
- rANS token profile (`AX_TOK=rans`, chunk entry bit 62) and the open profile (`AX_PROFILE=open`:
  tokens rANS, literal chunks mode 2 open DNA pack / mode 3 open plain, spec §3.4): an archive without
  a single zstd frame. Read by the C++, C99, Python and GPU decoders; the GPU tool decodes it without
  any nvCOMP call (k_rans, k_open_seq/cse/exc). The open profile is +4.4 % (chr1) / +3.8 % (T2T)
  larger than the zstd profile with the same encoder: the price of no zstd.
- Open profile CPU decode: bases unpacked by table; 16 KiB region on chr1 (C99, 64 KiB literal
  chunks) 189 -> 157 us; the persistent region handle of 2.1.0 reads every profile.
- C++ reader hardening: literal chunk table validated against the stream, DNA pack (mode 1) framing
  checked, reserved literal flags rejected, varint shift bounded (fuzzing, 3000 runs, 0 crashes).

GPU tool (`aceapex_gpu.cu`, measurement harness, not a library yet)
- `--pipeline=auto`: the copy of batch k+1 under the decode of batch k when the estimated H2D is at
  least half the on-device time and there are >= 2 batches of >= 64 MB; else sequential.
- RTX PRO 6000 Blackwell Server Edition, Colab, 27b61b1, 16 KiB blocks / 64 KiB literal chunks,
  median of 3, every row bit-perfect (FNV of the GPU output == original), libzstd 1.5.5:

  | corpus | profile | bytes | on-device ms | GB/s | with H2D ms |
  |---|---|---|---|---|---|
  | chr1 | zstd | 60 442 704 | 3.501 | 72.5 | 4.547 |
  | chr1 | open | 63 083 287 | 2.826 | 89.9 | 3.919 |
  | T2T | zstd | 822 393 156 | 35.542 | 88.8 | 49.759 |
  | T2T | open | 853 264 869 | 27.135 | 116.3 | 31.063 (pipeline, 101.6 GB/s) |

  Before l1 (same GPU): chr1 zstd 69 410 925 B / 5.18 ms, open 67 975 888 B / 3.68 ms; T2T open
  887 641 942 B / 26.66 ms.
- Open profile on five GPUs (chr1, before l1): T4 20.51, L4 10.14, A100-40GB 6.17, A100-80GB 6.09,
  Blackwell 3.69 ms on-device (README, results/gpu-open-table.md).

Closed by measurement (kept out of the default path; numbers in ROADMAP "Не делать")
- Two-pass CPU block decode (ops list, then copies): 20-28 % slower on one thread.
- Match-source prefetch ring in the CPU decoder: 9-26 % slower at every depth 2-16.
- One GPU kernel for the seq piece and the base expansion: +49 % (chr1), +46 % (T2T).
- dense-open (order-1 literals) as a format mode: after l1 -0.36 % (chr1) / -2.18 % (T2T) bytes; the
  measurement code (components/rans1_seg.c, k_r2) stays.

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
