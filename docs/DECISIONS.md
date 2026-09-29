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

## Open
- GPU figures in the README were taken in July on code that predates the literal
  transform, literal chunking and the chunk field. The README front page is rewritten
  only after they are re-measured on the current code (plan B3), with dates.
- Second decoder: ours, in C99 (ADR-009). A third-party implementation from the
  format document is still missing; that is what a standard needs.
- `rans1_v4` (order-1 literals) replaces the DNA transform rather than adding to it;
  the default ratio would be recomputed as a whole. Undecided.
