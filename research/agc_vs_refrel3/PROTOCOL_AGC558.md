# PROTOCOL_AGC558 - AGC 3.2.4 vs refrel3 v1 on all 558 HPRC assemblies (written before any measurement)

Status: draft for approval. After approval this file is not changed; any deviation is reported as a deviation.

## 1. Corpus

- The 558 rows of the manifest `research/refrel/logs/cohort-v1-manifest-2026-10-04.tsv` (year-1 94, release 2 464).
- FASTA of every assembly = the q16k v1 archive decoded by `refrel3v1` (aceapex research/refrel @ 5b6d5ce) with every
  check on: block XXH3 and the XXH3 of the rebuilt FASTA == the header's `fasta_xxh3` == the manifest's `fasta_xxh3`
  (the XXH3 of the source file recorded when the source was on disk). A decode that fails any check writes nothing.
- The FASTA is never stored: it is streamed to AGC through a named pipe (FIFO) per assembly by `fifo_feed`
  (one process, the decoded T2T loaded once, one thread per FIFO, at most 4 decodes at a time), only if the method
  check of section 3 passes.
- Reference: T2T-CHM13v2.0 FASTA (md5 cd1e52ce400c027ed0b7ab4b9d613f5a).
- Set names in AGC = manifest names (`y1_...`, `r2_...`), from the FIFO file names `<manifest name>.fa`.

## 2. AGC archive

- AGC 3.2.4 built from source tag v3.2.4, commit e67e3fc (`.wk/tools/agc-src`, its makefile: g++ -O3 -march=native
  -std=c++20); the same build for create, CLI queries and `libagc.a` (in process).
- One call: `agc create -d -k 31 -l 20 -s 60000 -b 50 -t 16 -o agc558.agc <T2T> <558 FIFOs in manifest order>`
  (k, min match, segment and batch as `t2t_50.agc`; `-d`: no command line stored). Wall time and peak RSS of the call
  recorded (`/usr/bin/time -v`). T2T alone with the same build and options: `agc create -d ... -o t2t_alone.agc <T2T>`
  (subtracted in the size table).
- Integrity before any timing (all must pass, else STOP and report; no measurement):
  1. `agc listset` == T2T + the 558 manifest names, nothing else;
  2. for every assembly: `agc listctg` == the contig names of its manifest FASTA, same order;
  3. for every assembly: `agc getset -l <its line width (60 release 2, 80 year-1)>` -> XXH3 of the output == the
     manifest's `fasta_xxh3`.

## 3. Method check (before section 2; N = 5)

The first 5 manifest assemblies (sources on disk, `.fa.gz` SHA-256 == the year-1 index):
1. `agc create` (options of section 2) from regular files `<dir>/<name>.fa` (gunzip of the sources), twice:
   both archives byte-identical (AGC deterministic for these options), else STOP;
2. the same `agc create` with the same paths replaced by FIFOs fed by `fifo_feed` from the q16k v1 archives:
   archive byte-identical to 1, else STOP and report (e.g. AGC reading an input twice) - no workaround.

## 4. Measurement

- Host ace-core (AMD EPYC 4344P, 8 cores / 16 threads, 125 GB); silence gate before the runs: load < 0.5, > 20 GB
  free; top processes and the background (openhands, glyph) recorded; nothing else run during the runs.
- Requests (unchanged from the N = 558 preparation, coordinates from the v1 contig tables; sample column = manifest
  name): 10 000 windows of 8 192 bases uniform over every valid start of the 558 (a window never crosses contigs),
  `random.Random(20261003)`; 1 000 regions (assembly uniform, contig by length, length 1 + floor(2^(20 u)) capped,
  start uniform), `random.Random(20261005)`; whole samples: the first 4 manifest assemblies.
- Truth: `truth_v1` (every q16k v1 archive decoded with every check, then SHA-256 of the upper-case bases of every
  request and sample).
- Formats and paths:
  - refrel3 q4k and q16k, in process (`rr3bench`, aceapex 5b6d5ce code; reference and archives opened before timing);
  - AGC in process (`agcbench`, `agc_get_ctg_seq` of `libagc.a` e67e3fc, one handle per thread, prefetching = 1);
  - AGC CLI (`agc_cli_batch.py`: all requests of a run in one `agc getctg -t T` process; wall time) - separate rows.
- Threads 1 (pinned, `taskset -c 3`) and 16. 3 warm-ups + 9 timed runs per configuration; reported: median, min,
  max, all 9 raw times; windows/s, regions/s, s per sample.
- Size table: AGC archive minus T2T alone (and the total), refrel3 q4k / q16k without block hashes (main) and with
  them (separate row), T2T separately (inside AGC; 3.16 GB FASTA decoded for refrel3).

## 5. FAIL criteria

- A row is FAILED (no time published) if any answer of any run (warm-ups included) differs from the truth by SHA-256,
  or any request returns an error, or the process crashes or is killed (e.g. out of memory).
- The whole measurement is not started if section 3 or the integrity checks of section 2 fail, or the silence gate
  does not pass.
- Runs are not repeated selectively; a rerun repeats the whole configuration and both results are kept.
