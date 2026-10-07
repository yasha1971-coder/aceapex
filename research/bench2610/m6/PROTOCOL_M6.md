# PROTOCOL_M6 v1.1 - AGC 3.2.4 against the cohort size N, refrel3 on the same N; counters for the hypotheses H1-H5

Status: frozen before any M6 measurement (SHA-256 in `PROTOCOL_M6.sha256`, committed before the runs). v1.1 (before any
run on N >= 50): section 7 changed after the method check on N = 5 showed the v1 profile of 100 windows dominated by the
archive open and unresolved kernel samples (logs/N5/perf_*_v1.* kept); the perf part of the N = 5 check is repeated
under v1.1 (the other parts are not changed by v1.1). Supersedes the
draft `../PROTOCOL_AGC_SCALING.md` (approved): same archives, method and statistics; requests as the user's D2 (windows
W = 4 096, 1 Mb regions, whole samples); counters and profile per G1 (H1-H5, source-only map of AGC e67e3fc, not in the
repository). A change after freezing is a new version and a full rerun.

## 1. Question

How the time of one request in AGC 3.2.4 (library path, explicit sample) changes with the number N of assemblies in one
archive, for the same request pattern, against refrel3 v1 q4k / q16k on the same N; and which counted work goes with
it. The report states numbers and counter values only; no cause is written beyond what the counters and profiles show.

## 2. Archives

- N in {50, 100, 200, 558}: the first N rows of the v1 cohort manifest (`.wk/hprc_cohort/v1/manifest_v1.tsv`, = the
  manifest of research/refrel/logs/cohort-v1-manifest-2026-10-04.tsv), manifest order, set names = manifest names.
- AGC 3.2.4 build of M1 (`.wk/tools/agc-src`, e67e3fc, g++ 11.4 -O3 -march=native -std=c++20): per N one
  `agc create -d -k 31 -l 20 -s 60000 -b 50 -t 16 -o agcN.agc <T2T> <N FIFOs>`, FIFOs fed by `fifo_feed` from the q16k v1
  archives (every check on) - the method of PROTOCOL_AGC558. N = 558: `agc558.agc` of M1 (SHA-256 9011701c...) reused.
- Per create: `/usr/bin/time -v` (wall, peak RSS), bytes, SHA-256.
- Completeness before any measurement on that archive (`integrity`): `listset` == T2T name + the N names in order;
  for every set `listctg` == the contig names of its v1 archive in order (count and names). A mismatch stops M6 for that
  N (the archive is our build defect, as in M1; nothing is measured on it).
- refrel3: the q4k and q16k v1 archives (with block XXH3) of the same N assemblies.

## 3. Method check on N = 5 (before section 2 for N >= 50)

The same create, integrity, request generation (5 assemblies), truth, one warm-up + one timed run of every row of
section 5 at threads 1, the counters of section 6 on 100 windows, the H5 stack check and one perf record of 1 000 windows.
Pass = create and integrity pass, every answer == truth, every counter file and perf report produced, H5 confirmed.
If it fails, nothing of section 5 runs.

## 4. Requests and truth (per N; from the contig tables of the N v1 archives)

- windows: 10 000 windows of W = 4 096 bases, uniform over every valid start of every contig of the N assemblies (a
  window never crosses contigs), `random.Random(20261011 + N)`;
- regions: 100 regions of exactly 1 000 000 bases, uniform over every valid start of every contig >= 1 000 000 bases,
  `random.Random(20261111 + N)`;
- whole samples: the first 4 manifest assemblies (every contig in full, FASTA order);
- truth: `truth_v1` (every v1 archive decoded in full, block XXH3 and source FASTA XXH3 checked), SHA-256 of the upper-case
  bases per request and per sample. Request files and truth: SHA-256 recorded before the runs.

## 5. Timing

- Host ace-core (AMD EPYC 4344P, 8 cores / 16 threads, 125 GB). Silence gate before each N series: load average < 0.5,
  > 20 GB free disk, background processes recorded; nothing else of ours running (no build, no create, no copy).
- Rows per N: AGC in process (`agcbench`, libagc e67e3fc, one handle per thread, prefetching = 1) and refrel3 q4k / q16k
  in process (`rr3bench`): windows, regions, whole samples; threads 1 (`taskset -c 3`) and 16; 3 warm-ups + 9 timed runs;
  reported median, min, max and the 9 raw times; requests/s, mean s per request, s per sample; open time; peak RSS.
- A row is FAILED (no time published) if any answer of any run (warm-ups included) differs from the truth by SHA-256.
- No selective repeats: a rerun repeats the whole row and both results are kept.

## 6. Counters for H1-H5 (counting build; never timed)

- Counting libagc: a copy of the AGC e67e3fc sources with event counters (`counters/patch_agc.py`), every zstd call of
  the library through counting wrappers keyed by call site (`counters/cnt.h`), compiled with the M1 flags + -g;
  `counters/agccount` (one handle, one thread, requests in file order). Per request: operator new / delete calls and
  bytes (H1), ZSTD_createDCtx / freeDCtx / decompress per call site with compressed and decompressed bytes (H1, H3,
  metadata vs reference vs delta by site), GetContigString calls and converted bytes (H1), contigs scanned and segment
  descriptors copied in get_contig_desc, descriptors scanned and segments decoded in decompress_contig (H2), reference /
  delta sizes into LZ decode, reverse complements, assembled vs returned bytes (H3), metadata batch loads and clears
  (H4), decompress_contig fast = false / true (H5). Every answer SHA-256 == truth.
- Inputs per N: the first 1 000 windows of the window file in file order, the same 1 000 sorted by (manifest order of
  the sample, contig, start) (H4: batch changes separated from payload), and the 100 regions.
- H5 before any timing: gdb on the counting build, breakpoint in CAGCDecompressorLibrary::decompress_contig for one
  window; the backtrace (agc_get_ctg_seq -> CAGCFile::GetCtgSeq -> GetContigString -> decompress_contig) and the value
  of `fast` are kept; and `dc_fast_false` == `dc_calls` for every counted request.

## 7. Profile

- `perf record -e cycles:u -g --call-graph fp` (user space only; perf_event_paranoid = 1 on ace-core) of `agcbench req`
  over all 10 000 windows of the N (method check: the first 1 000), one thread pinned, 0 warm-ups, 1 timed pass, on a
  profiling build (the same libagc sources and flags + -fno-omit-frame-pointer -g, not patched); every N.
- Report: top 20 functions by self and by children time per N, restricted to call chains under agc_get_ctg_seq
  (`perf report --parent agc_get_ctg_seq -x`; open and truth reading excluded), plus the share of all samples that lie
  under agc_get_ctg_seq; raw reports kept as evidence. If perf is refused, the row is "not run" with the setting recorded.

## 8. Evidence and report

`m6/` : scripts, logs per row (RUN lines), create `time -v`, integrity output, request / truth SHA-256, counter files,
perf reports, silence gates; RESULTS_M6.md with one table per request kind (N x tool x threads) and CSV curves
(`curves_*.csv`: N, tool, threads, median s per request, req/s, min, max, peak RSS; counters medians per N).
Hardware, OS, compiler, versions, flags, git hashes of aceapex and AGC, protocol SHA-256 in RESULTS_M6.md.
