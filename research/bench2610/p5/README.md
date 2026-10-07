# P5 - truth tables for PROTOCOL_FAIDX (P1) and PROTOCOL_COHORT_REGION (P3), ace-core 2026-10-06/07

SHA-256 of every expected answer (not the bytes). samtools / htslib 1.24 (`~/build/htslib-latest`, `versions.txt`).

- P1 (`p5.sh`, `make_requests.py`, `truth_samtools.py`): corpora chr1 (hg38, md5 9465e0f0...), T2T (md5 cd1e52ce...),
  HPRC4 (HG00438.1/.2, HG00621.1/.2 unpacked from `.fa.gz` with SHA-256 == the year-1 index); `.fai` built in the work
  directory (the golden corpora are linked, not written). 15 request files `req_p1/<corpus>_L<L>.tsv` (10 000 each,
  seeds 20261007 + i) and truth `truth_p1/` (samtools faidx -r, sequence lines joined, case kept); 2 min 25 s.
- P3 (`p5_p3.sh`): `req_p3/regions20.tsv` (the 20 triples, seed 20261008), `req_p3/requests.tsv` (11 160 requests:
  20 x 558, none skipped). Truth (a) `truth_p3/truth_v1.tsv`: every q16k v1 archive decoded with every check (558 / 558
  FASTA XXH3 == source); (b) `truth_p3/truth_samtools50.tsv`: samtools on the 50 uncompressed sources; (a) == (b) on the
  50: 1000 / 1000.
