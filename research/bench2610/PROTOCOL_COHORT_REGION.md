# PROTOCOL_COHORT_REGION (M3) - the same 20 region requests from every one of the 558 HPRC haplotypes (CPU)

Status: draft. Frozen before M3 (SHA-256 in `cohort_region/PROTOCOL_COHORT_REGION.sha256`).

## 1. Task

One task = 20 region requests answered from each of the 558 assemblies of the manifest (11 160 answers).

The regions are defined per assembly by one rule (no liftover; the 20 regions are NOT the same genomic loci across
assemblies - they are the same request pattern applied to each assembly's own coordinates):
- region j (j = 0..19) has length L_j and asks contig rank r_j of the assembly (contigs sorted by length descending, ties
  by name; rank 0 = longest) at relative offset f_j: start = floor(f_j x (contig length - L_j)) (0-based), end = start + L_j;
- L_j drawn once from [50 000, 1 000 000] (log-uniform), r_j from {0..9}, f_j from [0, 1), all with
  `random.Random(20261008)`; the 20 triples are written to `regions20.tsv` before any measurement.

## 2. Truth

- For the 50 assemblies whose source `.fa.gz` is on disk (SHA-256 == index): samtools faidx (htslib 1.24) on the
  uncompressed FASTA streamed one at a time (P5).
- For all 558: the q16k v1 archive decoded with every check (FASTA XXH3 == the manifest's, i.e. the source file's), then
  the regions cut (`truth_v1`); for the 50 above both truths must agree (else STOP).
- Stored: SHA-256 of every answer (upper case not applied: case as in the FASTA).

## 3. Ways (CPU, ace-core)

| row | storage | access |
|---|---|---|
| FASTA.gz + faidx | per assembly BGZF (`bgzip -@ 16`, level 6) + `.fai` + `.gzi` | `faidx_fetch_seq64` in process, files opened once |
| AGC 3.2.4 | `agc558.agc` of M1 (one create, integrity PASS) | `agc_get_ctg_seq` in process (libagc e67e3fc), and AGC CLI `getctg` with all requests in one process (separate row) |
| refrel3 q4k, q16k | the v1 archives of the manifest + the decoded T2T | refrel3 v1 window decode in process |

FASTA.gz + faidx is built and measured on the 50 assemblies only (not keeping 558 BGZF files: ~0.8 GB each); its 558
size and time are a CALCULATION (x 558 / 50), marked as such, never mixed with measured cells.

## 4. Measurement

- Silence gate; threads 1 (pinned) and 16; 3 warm-ups + 9 timed runs of the whole task; seconds per task (median / min /
  max / 9 raw), answers/s; bytes on disk (archives + indexes; refrel3 + T2T FASTA separately); peak RSS.
- Every answer of every run SHA-256 == truth; else the row is FAILED.
- GPU row (panvram on Colab, C1 b) is reported separately (other hardware).
