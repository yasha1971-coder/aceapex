# Defect of our archive build: two sets of the append-built t2t.agc lack most contigs (not an AGC error)

Found during the N = 558 comparison (`../README_558.md`). Archive `t2t.agc` (4 559 638 761 B, 561 sets: T2T, the 558
HPRC assemblies of the manifest, CHM13 v1.1, GRCh38) was built by a chain of appends with the AGC 3.2.4 release binary
(build 20260722.1): `agc create` with T2T, `agc append -t 8` one assembly at a time up to N = 88, then
`agc append -t 16` in batches of 10 `.fa.gz` files (`research/refrel/cohort_pipeline.sh`, `cohort_pipeline2.sh`).

Two sets hold only part of their source:

| set | contigs in the source FASTA | contigs AGC lists |
|---|---:|---:|
| r2_NA19682_hap2_hprc_r2_v1.0.1 | 72 | 4 |
| r2_HG01175_mat_hprc_r2_v1.0.1 | 59 | 3 |

The contigs are absent from the archive itself (`agc listctg`), so AGC's answer for them (`There is no sample:contig
pair: <set> : <contig>`) is correct: this is a defect of how we built the archive (a chain of appends; one batch most
likely wrote these sets incompletely), not an AGC error. It is not to be reported to the AGC authors unless it also
appears with a clean `create`. Which batch, its log lines and exit codes: section "Build trace" below (filled after the
N = 556 run).

Files: `sources.tsv` (URL and md5 of the two sources from the manifest), `<set>.source_contigs.tsv` (contig names and
lengths of the source FASTA, from the v1 archives whose FASTA XXH3 == the source's), `repro.sh` (CLI) and
`repro_lib.c` (C API), `repro_output.txt` (their output on ace-core).

## Build trace (from `.wk/hprc_cohort/agc.tsv`, `pipeline.log`, `research/refrel/cohort_pipeline2.sh`)

| set | manifest row | append batch (rows) | batch result | archive growth of the batch | batch wall |
|---|---:|---|---|---:|---:|
| r2_HG01175_mat_hprc_r2_v1.0.1 | 367 | 359 - 368 (`agc append -t 16`, 10 `.fa.gz`) | exit 0 (no "AGC batch append FAILED" line), nothing on stderr in the log | +46.0 MB | 92.9 s |
| r2_NA19682_hap2_hprc_r2_v1.0.1 | 514 | 509 - 518 (same) | exit 0, nothing on stderr | +57.3 MB | 99.0 s |

Neighbouring batches grew by +33.5 ... +65.5 MB in 98 - 111 s. Each `.fa.gz` was checked against its HPRC index hash
(md5 for release 2) before it entered a batch, refrel3 encoded it and decoded it back == FASTA, and the pipeline deleted
the `.fa.gz` right after the batch append - so the exact input AGC read cannot be inspected now. Cause: not established;
the defect is in our append-chain build (the archive lacks the contigs; AGC's answers for absent contigs are correct).
The new comparison does not use this archive (PROTOCOL_AGC558: one `create` from verified FASTA).
