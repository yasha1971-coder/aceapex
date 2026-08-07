# DATA — Provenance for ACEAPEX Reproduction (accession + md5)

All benchmark numbers in ACEAPEX papers use these exact inputs. A reviewer can obtain
them independently by accession and verify by md5. **Measure only from these** (honest,
non-degenerate). Defective/degenerate inputs (e.g. quality-2 FASTQ) are excluded and
produce misleading ratios — see note at bottom.

## Primary genomics input (Papers 2-5)
```
File:      NA12878 / ERR194147 (first 1,073,741,620 bytes = 1 GiB prefix)
Accession: ENA ERR194147  (https://www.ebi.ac.uk/ena/browser/view/ERR194147)
md5:       9af9ffaa0e15dba938408a711740e101
Quality:   Phred qual38 (by-eye verified real quality distribution, NOT degenerate)
Use:       D1-dense throughput, seek O(1), 50GB scale, min_match_len lever
```

How to obtain the exact 1 GiB prefix:
```bash
# download ERR194147 from ENA, then take first 1073741620 bytes:
head -c 1073741620 ERR194147.fastq > NA12878_REAL.fastq
md5sum NA12878_REAL.fastq   # must be 9af9ffaa0e15dba938408a711740e101
```

## Text input (Paper 5 data-type curve)
```
File:      enwik9 (first 1e9 bytes of English Wikipedia dump)
Source:    http://mattmahoney.net/dc/enwik9.zip
md5:       e206c3450ac99950df65bf70ef61a12d
Use:       parse-bound data point (min_match_len lever +2.7%)
```

## Mixed-data input (Paper 5 parse-bound extreme)
```
File:      silesia.tar (Silesia corpus, 12 files, tarred)
Source:    http://sun.aei.polsl.pl/~sdeor/index.php?page=silesia
Use:       strong parse-bound data point (min_match_len lever +20.2%)
```

## Repetitive inputs (seek universality)
```
pizzachili dna.200MB / english.200MB / proteins.200MB
Source:    http://pizzachili.dcc.uchile.cl/texts.html
Use:       seek O(1) across data types (bit-perfect)
```

## Reproduction recipe
See `BUILD_D1_DENSE.md` for exact build, then `reproduce_paper5.sh` for the
min_match_len lever sweep. Judge of correctness = bit-perfect round-trip (FNV hash
printed by e2e_dense MATCHES original).

## Note on excluded (degenerate) data
Earlier ACEAPEX numbers that appeared anomalously high (e.g. FASTQ ratio 11-14, throughput
260+) came from a DEFECTIVE NA12878 file with quality collapsed to ~2 symbols ("????"),
which is NOT representative. All published numbers use the honest ERR194147 (md5 9af9ffaa)
above. Per reproducibility law: a stranger reproduces from public repo + this accession alone.
