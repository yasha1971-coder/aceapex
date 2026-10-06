# PROTOCOL_FAIDX (M2) - region access: FASTA index / BGZF against ACEAPEX and refrel3 on the CPU

Status: draft. Frozen before M2 (SHA-256 of this file in `faidx/PROTOCOL_FAIDX.sha256`); a change after freezing is a
new version and a full rerun.

## 1. Corpora (read-only sources; SHA-256 / md5 recorded in the evidence)

| corpus | file | identity |
|---|---|---|
| chr1 | `~/golden/genome/chr1.fa` (hg38 chr1, UCSC) | 253 935 557 B, md5 9465e0f0df6e2c6eb39729c39cee5465 |
| T2T | `~/golden/genome/t2t.fa` (T2T-CHM13v2.0) | 3 156 259 565 B, md5 cd1e52ce400c027ed0b7ab4b9d613f5a |
| HPRC x 4 | HG00438.1, HG00438.2, HG00621.1, HG00621.2 (`.fa.gz` SHA-256 == the year-1 index; unpacked FASTA as in the manifest) | manifest `fasta_xxh3` |

## 2. Requests and truth

- Per corpus and length L in {100, 1 000, 10 000, 100 000, 1 000 000}: 10 000 regions `contig:start-end` (1-based
  inclusive, as samtools), uniform over every valid start of every contig with length >= L (contig chosen with weight =
  number of valid starts), `random.Random(20261007 + i)`, i = index of L in the list. HPRC: over the four assemblies
  together (assembly + contig + start).
- Truth (P5): `samtools faidx` (htslib 1.24, `~/build/htslib-latest`) on the uncompressed FASTA; the answer = the
  sequence lines joined without line ends, case kept; the SHA-256 of every answer is stored (`truth/<corpus>_L<L>.tsv`:
  id, SHA-256), not the bytes.

## 3. Formats (every configuration built once; build command, wall time, peak RSS and sizes recorded)

| row | archive | access path (in process) |
|---|---|---|
| BGZF default | `bgzip -@ 1 -i` (htslib 1.24, level 6, block <= 65 280 B) + `.fai` + `.gzi` | htslib `fai_load3` once, `faidx_fetch_seq64` |
| BGZF g = 4 KiB, g = 16 KiB | written by our writer with htslib `bgzf_write` + `bgzf_flush` every g uncompressed bytes (one BGZF block per g bytes; level 6), `bgzf_index_build_init` for `.gzi`; `.fai` by `fai_build` | same as BGZF default |
| ACEAPEX interactive g = 4 KiB, 16 KiB | ACEAPEX 2.2.2 CLI (`ACEAPEX_CLI` build with env tuning): `ACEAPEX_BS=<g> FSE_CHUNK=4096 LIT_CHUNK=65536` (the interactive layout of FORMAT_STREAMS), level default | `aceapex_decompress_region` (library built without env tuning) on the archive in memory, byte offsets from the `.fai` line arithmetic, line ends removed |
| refrel3 q4k, q16k (HPRC only) | the v1 archives of the manifest (with block XXH3) against the decoded T2T | refrel3 v1 window decode (`block_v1` over the touched blocks), contig offset from the archive's contig table |

refrel3 on chr1 and T2T: n/a (refrel3 encodes assemblies against T2T; T2T is the reference itself; chr1 of hg38 is not
in the cohort) - reported as n/a, not timed.

## 4. Measurement

- One measuring binary for all formats (`regbench`: libhts 1.24, libaceapex 2.2.2, refrel3 v1 @ 5b6d5ce), checked on 50
  requests per corpus x format against the truth before the measurement (all 50 == truth, else STOP).
- Host ace-core; silence gate (load < 0.5, > 20 GB free, background recorded); nothing else running.
- Archives and indexes loaded before timing (file-backed formats: the file in the page cache after the warm-ups).
- Per corpus x L x format: threads 1 (pinned, `taskset -c 3`) and 16; 3 warm-ups + 9 timed runs of all 10 000 requests;
  1 thread: per-request latency p50 / p99 over all timed runs + requests/s; 16 threads: requests/s; median / min / max /
  9 raw run times. Peak RSS of the process per configuration. Every answer of every run SHA-256 == truth.
- Size: archive + every index needed for the access path, per corpus.

## 5. FAIL

Any answer != truth, any error, crash or kill -> the row is FAILED (no time). Failed 50-request check or silence gate ->
the measurement does not start. Reruns repeat the whole configuration; both results kept.
