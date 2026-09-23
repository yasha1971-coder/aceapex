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

## Open
- GPU figures in the README were taken in July on code that predates the literal
  transform, literal chunking and the chunk field. The README front page is rewritten
  only after they are re-measured on the current code (plan B3), with dates.
- Second independent decoder: none. Blocks any path to a standard.
- `rans1_v4` (order-1 literals) replaces the DNA transform rather than adding to it;
  the default ratio would be recomputed as a whole. Undecided.
