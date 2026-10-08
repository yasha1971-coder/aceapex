# Window-law verdict job (hw-apex series B, protocol v1.1) - HPRC N = 4 on ace-core, 2026-10-08

Harness: hw-apex-bench PR #63 at 0ace54d (tree 06fd3c5f), protocol v1.1 SHA-256
4a0027fec59b3252dc07b29458a57a5a451957f1b64b36f3927765cbc6be7a5c, `tools.verdict_refrel3` prepare -> run -> verify.
Run: 2026-10-07 23:49:58 UTC -> 2026-10-08 02:11:31 UTC (8 493 s wall, peak RSS 33.0 GB), one thread, seed 20261003,
10 000 requests per W, W = 1, 2, 4, ..., 65536 (verdict at 1024 / 8192 / 65536, W = 1 calibration only), D_Q = 3 warm-ups +
9 recorded full sequential decodes with SHA checked outside the timer. Silence gate PASS at start (load1 0.43).
`verify`: VERDICT_EVIDENCE_PASS; `sha256sum -c SHA256SUMS`: all OK. Evidence (1.1 GB with every window log):
`window-law-B-0ace54d-2026-10-08.tar` on Drive ACEAPEX-OVH/outgoing; summary files, dq logs, plan, receipts in `hprc4/`.
Method check first: the same job on 4 clean-room fixtures (`rehearsal/`, 7 formats measured, verify PASS).

Cohort: y1_HG00438.1 / .2, y1_HG00621.1 / .2 (source URL and .fa.gz SHA-256 of MANIFEST.tsv), canonical domain
uppercase sequence bytes without FASTA framing (12 009 829 249 B). Archives built on ace-core from the pinned sources:
refrel3 v1 q4k / q16k (manifest archives), BGZF default (bgzip -@ 1, libdeflate) and matched-g (explicit flush every
4 147 raw bytes = 4 096 bases at 80-base lines), zstd seekable 1.5.7 (level 3, 16 KiB frames of the canonical stream),
LZ4 1.10.0 independent 4 MiB blocks of the canonical stream, OZSEG (OpenZL 0.3.0 segmented container, 4 variants;
the whole-frame adapter of 05.10 could not compress these inputs, the segmented one does). AGC: FAILED by the job -
no retained source-level canonical-granule evidence (`agc/GEOMETRY_MISSING.*`); Q was not guessed.

## Verdicts (model B: t(W) = c0 + (W + Q - 1) / D_Q, c0 = p50(W = 1) - Q / D_Q, threshold |error| <= 20 %, c0 < 0 = FAIL)

| format | variant | Q (canonical B) | D_Q (GB/s) | c0 (us) | p50 1 KiB / err | p50 8 KiB / err | p50 64 KiB / err | verdict |
|---|---|---:|---:|---:|---|---|---|---|
| refrel3 | q4k | 4 096 | 2.068 | 7.25 | 9.87 us / +1.5 % | 13.37 us / +1.3 % | 42.25 us / +3.2 % | **PASS** |
| refrel3 | q16k | 16 384 | 2.085 | 6.79 | 15.12 us / -0.1 % | 18.08 us / -2.7 % | 47.58 us / +3.2 % | **PASS** |
| BGZF | default | 64 399 | 0.859 | 3.17 | 78.40 us / -1.2 % | 78.98 us / -10.0 % | 157.2 us / +1.8 % | **PASS** |
| BGZF | matched-g 4147 | 4 096 | 0.610 | 4.55 | 11.72 us / -9.5 % | 24.68 us / -0.1 % | 122.6 us / +3.2 % | **PASS** |
| zstd seekable | level 3, 16 KiB frames | 16 384 | 0.449 | -15.66 | 21.03 us / -9.2 % | 22.18 us / -43.3 % | 99.07 us / -40.7 % | FAIL (c0 < 0; 8 and 64 KiB > 20 %) |
| LZ4 indexed | 4 MiB blocks | 4 192 248 | 0.857 | -3 234 | 1 659 us / 0.0 % | 1 687 us / +1.2 % | 1 693 us / -2.4 % | FAIL (c0 < 0) |
| OZSEG | l1_w64k | 65 536 | 0.428 | -26.0 | 126.7 us / -2.2 % | 135.8 us / -7.2 % | 257.3 us / -8.2 % | FAIL (c0 < 0) |
| OZSEG | l1_w1m | 1 048 576 | 0.385 | -376 | 2 349 us / 0.0 % | 2 349 us / -0.8 % | 2 355 us / -6.5 % | FAIL (c0 < 0) |
| OZSEG | l3_w64k | 65 536 | 0.406 | -24.4 | 138.6 us / -0.8 % | 138.3 us / -12.1 % | 277.8 us / -7.0 % | FAIL (c0 < 0) |
| OZSEG | l3_w1m | 1 048 576 | 0.386 | -386 | 2 330 us / -0.1 % | 2 331 us / -0.9 % | 2 376 us / -5.0 % | FAIL (c0 < 0) |
| AGC | t2t | - | - | - | - | - | - | FAILED: AGC canonical granule evidence is missing or not archive-bound |

Summary of results.json: refrel3_verdict PASS (both Q); foreign families with valid data 4 (bgzf, zstd-seekable,
lz4-indexed, ozseg), coverage_complete true; comparison_verdict FAIL and data_status FAILED (the AGC row is a data
failure; zstd / LZ4 / OZSEG are model-B failures with retained numbers). Every window SHA-256 of every format and
every full decode == the canonical source (no data failure except AGC).

What the numbers say, nothing more: for refrel3 and both BGZF configurations the one-term model with an independently
measured c0 predicts the 1 / 8 / 64 KiB window medians within 10 % (refrel3 within 3.3 %). For zstd seekable, LZ4 and
OZSEG the W = 1 probe is faster than Q / D_Q, so c0 is negative and model B fails by the protocol's rule; their window
times are nearly flat in W (one granule per request dominates: 4 MiB for LZ4, 1 MiB for OZSEG w1m), and the D_Q of
these readers includes the adapter's materialization of the full output (the frozen timed boundary of the job).

Reproduce: `make_root.py spec_hprc4.json` (archives as in `spec_hprc4.json`, built by the commands in this directory:
`lz4blocks.c`, zstd `seekable_compression`, hw-apex `bgzf_adapter.create`, `openzl_adapter.sh build`), then on the
clean harness at 0ace54d: `python3 -m tools.verdict_refrel3 run --root <root> --plan plan.json --out <out>` and
`verify --root <out>`.
