# AGC 3.2.4 vs refrel3 v1 on all 558 HPRC assemblies (ace-core, CPU in process) - run of 2026-10-06

AGC archive: `.wk/hprc_cohort/agc/t2t.agc`, 4 559 638 761 B, 561 sets (T2T + the 558 + CHM13 v1.1 + GRCh38), built by a
CHAIN OF APPENDS (create T2T; append one by one up to N = 88, then batches of 10; `research/refrel/cohort_pipeline*.sh`),
not by one `create`. refrel3: the v1 archives of the manifest (q4k, q16k). Set names: `names558.tsv` (manifest name ->
AGC set name). Requests: `windows_8192_558.tsv` (10 000 x 8 192, seed 20261003), `regions_558.tsv` (1 000, seed 20261005).

Truth: the sources of 508 of the 558 assemblies are not on disk, so `truth_v1.cpp` decodes every q16k v1 archive with
every check on (block XXH3 and the rebuilt FASTA's XXH3 == the source file's XXH3 recorded at encoding) before computing
the SHA-256 of the requests (`truth558_requests.tsv`) and samples (`truth558_samples.tsv`); 558 / 558 passed. Cross-check:
for the 50 samples whose source FASTA is on disk, the whole-sample SHA-256 equals the FASTA-derived truth of the N = 50
run, 50 / 50.

Runs: `run_558.sh`, logs `logs558/` (silence gate 2026-10-06 00:56 UTC, load 0.48). 264 runs.

## Result

- refrel3 q4k / q16k: every run of windows, regions and whole samples == truth.
- AGC whole samples (first 4): == truth.
- AGC windows and regions (in process and CLI): FAILED. `t2t.agc` holds only 4 of the 72 contigs of
  `r2_NA19682_hap2_hprc_r2_v1.0.1` and 3 of the 59 of `r2_HG01175_mat_hprc_r2_v1.0.1`; AGC answers "There is no
  sample:contig pair" for the rest (25 of the 10 000 windows, 5 of the 1 000 regions). The bench counts a run with any
  error as failed, so these rows carry no valid time. The cause of the incomplete sets in the append chain is not
  established (no error in the pipeline log; hypothesis: the batch append read those sources incompletely).
