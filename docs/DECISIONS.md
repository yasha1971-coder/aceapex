# Decisions

One entry per decision: date, what was decided, why, what it costs. Reversals are new
entries, never edits. Measured figures carry their host and libzstd version.

## ADR-001 (2026-09-23) Releases are snapshots, not milestones
A version number marks what a stranger can verify (`./verify.sh`), nothing about what
comes next. Fixes ship as soon as they are judged; a research result gets its own
release and paper. Consequence: v1.0.2 is a maintenance release for users of 1.0.1.

## ADR-002 (2026-09-23) The decoder fails closed
Every zstd frame is checked for error and exact size (`zdec_ok`); parallel paths raise
`g_dec_err`, entry points reset and check it, range paths return nullptr and the
library returns `ACEAPEX_ERR_DATA`. Before: a failed frame left malloc garbage and the
call reported success (region on a pre-field archive without `FSE_CHUNK`, 21.09).
Guarded by the contract claim `region_fails_closed_legacy`. Commit f3814f6.

## ADR-003 (2026-09-23) Ratio expectations are keyed by libzstd version
Archive bytes depend on the code and the libzstd version and on nothing else about the
host: identical to five decimals on 16/12/4/2 cores and three compilers at 1.5.5.
The contract carries the 1.4.8 figures (the papers) and the 1.5.5 figures, judged at
1e-5 on both; an unknown version gets 1 percent and says so in the record. Rejected:
a silent wide tolerance (3.2 to 3.8 percent since 1f92b5a) while the record said 1e-5.

## ADR-004 (2026-09-23) Core-count dependence of archive bytes: withdrawn
Suspected on 22.09 from three different default ratios; refuted: `LIT_LANES` 2 and 16
give byte-identical archives on chr1, enwik8 and silesia, and the differences were
libzstd (ADR-003). The 3.72329 default figure of 11.09 reproduces on no known host and
was replaced by 3.72821 (1.4.8) / 3.73164 (1.5.5).

## ADR-005 (2026-09-22) Paper tags are immutable; judges live in main
`verify.sh` checks each paper tag out into a detached worktree and runs
`verify/judges/<tag>.sh` from main, so a judge can improve without touching what was
submitted. A fail with a stated condition and reason (`verify/known/<tag>.tsv`) is
reported as `known-deviation` in its own column, never as pass. First entry: the
paper5-v1 ratios on libzstd other than 1.4.8.

## ADR-006 (2026-09-21) The CLI is built from the library translation unit
`make` compiles `src/aceapex_api.cpp` with `-DACEAPEX_CLI`: one copy of the codec, and
the CLI reaches the public API (`aceapex r`). `g++ src/aceapex_main.cpp` alone still
builds c/d/t. Judged: archives byte-identical to the previous binary. Commit 7e393f8.

## ADR-007 (2026-09-21) aceapex_depth.cpp stays a fork, unported, for now
The reproduction contract builds its encoder from `aceapex_depth.cpp` (4f0797f), a
2035-line fork that predates the chunk field; its archives are read by the library
through `FSE_CHUNK` in the environment, stated in the contract. Only the fork carries
`--fai`, `--region/--range`, `--profile`, `--view`. Porting the field into the fork or
merging the fork into `src/` is a separate decision; the contract is not the place.

## ADR-008 (2026-09-28) Cross-version fixtures are the format-safety claim
A 4 MiB slice of chr1 (offset 100 MiB) archived on each libzstd version we ship
against lives in `verify/fixtures/` (`chr1_4MiB.zstd-<ver>.aet`, tracked on purpose
through a `.gitignore` exception). The HEAD judge decodes every fixture on every host
and re-encodes the decoded slice against the fixture of the host's own libzstd. No
corpus is needed, so the claim runs in CI. Archive bytes depend on the libzstd version
(0.09 % between 1.4.8 and 1.5.5 at 16 KiB chunks); decodability does not.

## ADR-009 (2026-09-28) A second decoder, in C99, judged like the first
`c/aceapex_decode.c` is a standalone decoder: one translation unit, libzstd the only
dependency, no threads or globals, the same names and error codes as `aceapex.h`
(`aceapex_decompress`, `_region`, `_ranges`, plus `aceapex_decoded_size`). It reads
every layout the C++ decoder reads and fails closed on every frame and bound. The
BlockOffsets table sits at offset 68 and is read with `memcpy` (UBSan, ARM). It is
judged against the same fixtures (`head_cdecoder_*`) and is the piece meant for
embedding (bindings, databases, tools). Speed is not its goal; the C++ library keeps
the parallel paths.

## ADR-010 (2026-09-28) The GPU path reads the archive as written; G is probed
`aceapex_gpu.cu` decodes an `.aet` in one process: nvCOMP batched zstd writes frames
directly into the stream buffers, two kernels unpack DNA literal chunks, the v7-RA match
kernel finishes. The parser group width G is chosen at run time by a short probe
(T4 -> 32, H100 expected 8) instead of a compile-time constant. Measured on T4: the
bus is 2.3x shorter than the entropy decode, so H2D/decode overlap does not pay there
(each extra nvCOMP call costs ~1.1 ms); FSE chunks of 4 KiB decode faster than 64 KiB
on nvCOMP, so the interactive profile is also the GPU profile. No `--profile gpu`.

## ADR-011 (2026-09-28) An empty input is a valid archive of one header
`aceapex_compress` on zero bytes used to return 0 - "no archive" - which no caller
could round-trip (lzbench runs every codec on tiny inputs). An empty archive is now
exactly one 68-byte header: `num_blocks 0`, `orig_size 0`, four stream sizes 0,
`block_size 65536`, `xxhash` of zero bytes. Both decoders accept `num_blocks 0` only
under these conditions; a region of length 0 returns 0, any other length is an error.
Fixture `verify/fixtures/empty.aet`, claims `head_fixture_empty_*`, `head_cdecoder_empty`.

## ADR-012 (2026-09-28) The C decoder gets a persistent handle and per-cursor caches
`aceapex_dec_open/size/region/ranges/close` keep the parsed chunk tables, one
`ZSTD_DCtx` per stream and the last four decoded chunks of each stream between calls;
slices that span chunks are assembled by copying, never by decoding a chunk twice. The
stateless functions stay for one-shot use. Measured on a 64 MB DNA archive, random 16 KiB
regions: 492 -> 135 us (C++ library: 114); full decode 0.79 -> 0.245 s. The DNA unpack
writes bases and case through typed 256-entry tables (`uint32_t`, `uint64_t`), not
per-byte loops; the `__memcpy_chk` per 4 bytes that Ubuntu's fortified glibc turned the
first table version into was 44 % of the profile. The handle and table idea came from
the user's second agent as an uncommitted edit in the working tree; it was set aside,
judged like an external patch (three compilers, 17 fixtures, ASan/UBSan, 900 fuzz runs),
then extended with the DCtx and chunk cache. Rule from this: a second agent works on a
branch and lands through `make test`, never by editing another session's working tree.

## ADR-013 (2026-09-29) Software releases are vX.Y.Z; vN.0 tags are paper artifacts
The repository carries `v2.0`, `v3.0`, `v4.0` (paper 2-4 artifacts, June-July 2026),
`paper5-v1`, `paper6-v1` and the software tags `v1.0.0`, `v1.0.0-beta`. From now on a
software release is always a three-component tag that equals `ACEAPEX_VERSION_STRING`
in `src/aceapex.h` (`v2.1.0`, later `v3.0.0` - distinct from the paper tag `v3.0`), with
a CHANGELOG entry and `make test && ./verify.sh` green on the tagged commit. Paper tags
stay frozen (ADR-005) and are never reused for software. The python package and the C
decoder header carry the same string. lzbench integrations name the software version.

## ADR-014 (2026-09-29) The decode thread budget covers the entropy phase; threads=1 spawns nothing
lzbench 2.4's published page (EPYC 9555P) showed aceapex 1.0.1 decode scaling x17.7 at
32 external threads against x22.3 for zstd -2, and internal scaling (`-I8`) of only
x2.5. On ace-core the 2.1.0 CLI reached a 31 ms floor in the entropy phase from four
threads on. Causes, measured on silesia: (1) the three token streams were decoded by
one thread each in the CLI and strictly serially in the library, while `#pragma omp`
in `fse_chunked_decomp` was dead (no `-fopenmp`; with it, one pool per stream
oversubscribed the cores: 42 ms against 32); (2) the library always used every
hardware thread for literals and eight for the match phase, so an external harness
running N copies got N x (lanes + 8) threads; (3) non-DNA archives use the legacy
4-lane literal layout, which caps literal parallelism at four (81.7 MB of silesia
literals / 4 = the 31 ms floor). Decision: every FSE chunk of every token stream is one
job in one pool; the entropy budget is split between literal lanes and that pool by
decoded bytes; `aceapex_decompress_mt(..., threads)` passes one budget through both
phases and `threads = 1` decodes on the caller's thread with no pthread_create; auto
means the hardware thread count. Not decided here: the default literal chunk for
non-DNA input (legacy 4 lanes vs 4 MiB chunks at +0.10 % on silesia) - the ratio axis
is the user's call.

## ADR-015 (2026-09-29) Block decoder copies in 16-byte steps; branch-free and interleaved variants closed
Single-thread decode of silesia on ace-core: entropy 98 ms, match phase 102 ms - the
match phase alone costs what zstd -2 spends on its whole decode (108 ms). With the
copies compiled out the phase still took 72 % of its time (container: 122 of 170 ms),
so the token loop, not the copying, is the cost. Kept: 16-byte wild copies for literal
runs and matches (a match closer than 16 bytes is first expanded byte-wise to a period
>= 16 - the ZSTD_overlapCopy8 / LZ4 technique, not ours), guarded by 16 bytes of slack
inside the block and the literal slice, the plain path for the tail: 199 -> 170 ms
single-thread on the container, bit-perfect, ASan/UBSan clean on 17 fixtures and
silesia, 40 bit-flip runs without a crash. Closed, measured worse on the same host:
(a) branch-light execution (256-entry token table, selects for the rep window,
branch-free 1..2-byte offset varint, unconditional copies redirected to a scratch line
for zero lengths): 241 ms; (b) two blocks per thread with one token each in turn:
241 ms. Neither branch prediction nor the dependency chain is the bottleneck on this
host; the next step is hardware counters on ace-core, not more variants.

## ADR-016 (2026-09-29) Match tables hold block-relative 32-bit positions; the chain is per block
lzbench 2.4's page: compression at level 2 scaled x8.3 over 32 threads where level 1 and
every other codec scaled ~x20 (ace-core -T8: x3.7 against x5.7 for zstd -2). Cause: each
thread carried a chain table of 2^20 int64 (8 MB, memset per call) plus int64 position
tables, and level 2 walks that chain 32 deep at random - 32 threads x 8 MB is a working
set past L3. Matches never leave the block, so positions are now stored relative to the
block start as uint32 (pos, chain), the chain has one link per block position (<= 4 MB
at the 1 MiB maximum block) and is reset per block, and a link is written only from a
position of the current epoch. Candidate order is unchanged: silesia and dickens
archives are byte-identical before and after (2 and 3 threads), the chr1 fixture
determinism claim holds. Container, 2 threads: encode silesia 6.43 -> 5.70 s. Also
removes a 32-bit truncation (`(int32_t)pos`) left from the 64-bit-position fix of
2026-07-24 that only lost matches past 2 GiB.

## ADR-017 (2026-09-29) The library encoder wrote a constant block size; the judge now round-trips the API
`aceapex_compress` stamped `BLOCK_SIZE` (1 MiB) into the header while `encode_file` had
cut the blocks with the adaptive size (256 KiB for a 300 KB input at one thread), so
every archive from the library with two or more blocks smaller than 1 MiB - inputs
between 256 KiB and 4 MiB x threads - decoded its first block and garbage after it.
The CLI wrote the right value, every fixture is CLI-made, the Python package only
decodes, and lzbench's 1.0.1 copy has fixed 1 MiB blocks, so nothing published saw it;
lzbench's own tiny-input run on the 2.1.0 branch found it (`common=262144/300000`).
Fix: the header carries `g_block_size`. New claim `head_api_roundtrip`
(`scripts/api_roundtrip.cpp`): 13 sizes across the block-size boundaries x random and
DNA-like bytes x both levels x 3 encode x 3 decode thread counts, 468 round-trips,
bit-perfect; on the unfixed code it fails 204 of them. Rule: every public entry point
gets a round-trip claim, not only the CLI.

## ADR-018 (2026-09-29) A zstd-free token profile: 32-lane rANS chunks, entry bit 62
The GPU path decodes the entropy layer with nvCOMP, whose zstd decoder is closed since
2.3; lzbench builds the open 2.2 and so cannot run it, and the Blackwell hardware engine
does not read zstd. StreamLZ (encode.su 4526) shows where this ends: its own GPU entropy
decodes at 32-77 GB/s. E1 (2026-09-29) priced order-0 rANS on the token streams at +3.5 %
of the streams in 4 KiB chunks; measured with a real coder in 64 KiB chunks the cost is
gone on genomes: chr1 slice offsets +0.28 %, commands -0.37 % against zstd -1 in the same
chunks, the whole archive +0.12 % against the default 512 KiB zstd chunks. Literals of DNA
archives are already the 2-bit pack decoded by our own kernel, so with this profile a
genome archive needs no zstd on the GPU at all. On text it costs more (silesia commands
+6.8 %) and literals stay zstd: the profile is for the genome niche, opt-in.
Decision: chunk entry bit 62 marks a rANS chunk (`src/ax_rans.h`, spec 3.1.1): 32 lanes
so one warp decodes one chunk, words stored in lane order so a lane finds its word by a
ballot and popcount, the chunk self-checks (every lane must end at the start state).
`AX_TOK=rans` writes it, with 64 KiB token chunks unless FSE_CHUNK is set; the default
output is unchanged byte for byte. All decoders read it: C++ (full, region, batch), C99,
Python, ARM; the two GPU tools decode such chunks on the host for now - the warp kernel
is the next step. Also fixed on the way, in every C++ reader: the chunk table is validated
against the stored stream length before use (a bad or future entry sent readers past the
buffer - v2.1.0 crashes on a bit-62 archive instead of refusing it), and chunk tables and
the block table are read with byte copies, not through misaligned uint64/BlockOffsets
pointers (UBSan in the region paths). Claims: conformance fixtures dna_rans_2MiB,
dna_rans_4k, text_rans_200K (CLI, C99, ARM64, ARMv7), ax_rans.h identical in src/, c/,
python/csrc/; 3000 unit round-trips and 300 bit-flip runs under ASan/UBSan clean.

## Open
- GPU figures in the README were taken in July on code that predates the literal
  transform, literal chunking and the chunk field. The README front page is rewritten
  only after they are re-measured on the current code (plan B3), with dates.
- Second decoder: ours, in C99 (ADR-009). A third-party implementation from the
  format document is still missing; that is what a standard needs.
- `rans1_v4` (order-1 literals) replaces the DNA transform rather than adding to it;
  the default ratio would be recomputed as a whole. Undecided.
