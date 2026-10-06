# PROTOCOL_AGC_SCALING (M6) - AGC: cost of one window against the cohort size

Status: draft. Frozen before M6 (SHA-256 in `agc_scaling/PROTOCOL_AGC_SCALING.sha256`); runs after P5 and R2, under the
silence gate. A change after freezing is a new version and a full rerun.

## 1. Question

How the time of one random window (W = 8 192) in AGC 3.2.4 changes with the number N of assemblies in the archive, for
the same request pattern, against refrel3 on the same N. Measured, not explained: no statement about the cause before
the profile of section 5.

## 2. Archives

- N in {50, 100, 200, 558}: the first N rows of the manifest (`research/refrel/logs/cohort-v1-manifest-2026-10-04.tsv`).
- AGC 3.2.4 from source e67e3fc: one `agc create -d -k 31 -l 20 -s 60000 -b 50 -t 16 -o agcN.agc <T2T> <N FIFOs>` per N,
  inputs through `fifo_feed` from the q16k v1 archives (every check on), names = manifest names, manifest order - the
  method of PROTOCOL_AGC558 (dress rehearsal PASS: FIFO create == file create == t2t_50.agc). N = 558: `agc558.agc` of M1
  is reused (same build, options and inputs; SHA-256 9011701c...).
- Per create: wall time and peak RSS (`/usr/bin/time -v`), archive bytes and SHA-256, `listset` == t2t + N names.
- refrel3: the q4k and q16k v1 archives of the same N assemblies.

## 3. Requests and truth

- For each N: 10 000 windows of 8 192 bases uniform over every valid start of the N assemblies (a window never crosses
  contigs), `random.Random(20261011 + N)`; truth = `truth_v1` (v1 decode with the source XXH3 check), SHA-256 per window.

## 4. Measurement

- AGC in process (`agcbench req`, libagc e67e3fc, one handle per thread, prefetching = 1) and refrel3 q4k / q16k
  (`rr3bench req`); threads 1 (pinned) and 16; 3 warm-ups + 9 timed runs; median / min / max / 9 raw; windows/s and
  mean time per window; peak RSS per configuration. Every answer SHA-256 == truth, else the row is FAILED.
- Silence gate before the series; nothing else running.

## 5. Profile of one window (AGC, N = 50 and N = 558)

- `perf record -g` (or `perf stat` if call graphs are not available to the user) over 1 000 windows of the same request
  file, one thread, the same `agcbench` binary built with `-fno-omit-frame-pointer` (and otherwise the same flags);
  report: top functions by self and children time, per N; raw `perf report --stdio` output kept as evidence.
- No conclusion about the cause is written until both profiles exist; the report then states only what the profiles show.
- If `perf` is not permitted for this user (kernel.perf_event_paranoid), the profile row is "not run" with the setting
  recorded; no other profiler is substituted without approval.
