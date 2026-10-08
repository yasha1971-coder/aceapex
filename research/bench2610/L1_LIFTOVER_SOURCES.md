# L1 - reference -> haplotype coordinates for the 558 HPRC assemblies: published alignments and a plan (research only)

Status: sources and volume estimate; no code. Checked 2026-10-07 (HTTP HEAD sizes; one 300 MB streamed sample, nothing stored).

## 1. Published alignments of HPRC assemblies against T2T / GRCh38

| what | covers | format | size (Content-Length) | URL |
|---|---|---|---:|---|
| release 2, haplotypes vs CHM13 (wfmash) | 465 sequences: GRCh38 + release-2 haplotypes (our 464 `r2_` assemblies; year-1 assemblies are not in release 2) | PAF with `cg:Z` CIGAR (=/X/I/D), PanSN names `SAMPLE#HAP#contig` | 5 590 221 127 B (gz) | https://s3-us-west-2.amazonaws.com/human-pangenomics/pangenomes/freeze/release2/impg/pafs/hprc465vschm13.aln.paf.gz |
| release 2, haplotypes vs GRCh38 (wfmash) | same set vs GRCh38 | PAF + CIGAR | 6 342 372 371 B (gz) | https://s3-us-west-2.amazonaws.com/human-pangenomics/pangenomes/freeze/release2/impg/pafs/hprc465vsgrch38.aln.paf.gz |
| release 2, trace-point alignments (impg) | 466 files, one per target haplotype | TPA | 25 070 431 026 B in total | https://s3-us-west-2.amazonaws.com/human-pangenomics/index.html?prefix=pangenomes/freeze/release2/impg/tpas/ |
| release 2, Minigraph-Cactus multiple alignment, CHM13-based | release-2 haplotypes | TAF | 6 128 656 442 B (gz) | https://s3-us-west-2.amazonaws.com/human-pangenomics/pangenomes/freeze/release2/minigraph-cactus/v2.0/hprc-v2.0-mc-chm13/hprc-v2.0-mc-chm13.full.taf.gz |
| release 2, Minigraph-Cactus, GRCh38-based | same | TAF | 5 955 460 872 B (gz) | https://s3-us-west-2.amazonaws.com/human-pangenomics/pangenomes/freeze/release2/minigraph-cactus/v2.0/hprc-v2.0-mc-grch38/hprc-v2.0-mc-grch38.full.taf.gz |
| release 1 (year-1 assemblies), Minigraph-Cactus, CHM13-based | year-1 haplotypes | HAL (hal2paf needed) | 83 935 487 863 B | https://s3-us-west-2.amazonaws.com/human-pangenomics/pangenomes/freeze/freeze1/minigraph-cactus/hprc-v1.1-mc-chm13/hprc-v1.1-mc-chm13.full.hal |
| release 1, Minigraph-Cactus graph | year-1 | GFA | 9 473 687 712 B (gz) | .../freeze1/minigraph-cactus/hprc-v1.1-mc-chm13/hprc-v1.1-mc-chm13.gfa.gz |

Licence / terms: HPRC data - public domain / CC0 (AWS Registry of Open Data, s3://human-pangenomics: "Creative Commons CC0
1.0 Universal"; HPRC Data Use page, quoted in panvram DATASET.md). The release-2 alignment pipeline repository
(github.com/pangenome/HPRCv2) states MIT for its code.

Coverage of our cohort: release-2 PAF covers the 464 `r2_` assemblies (to be checked name by name before use). The 94
year-1 assemblies (49 samples; 44 of them also have different release-2 assemblies) are covered only by the release-1
Minigraph-Cactus HAL (84 GB) or by an alignment we would compute ourselves.

## 2. Volume estimate (from the streamed 300 MB sample of the CHM13 PAF)

Sample: 414 992 PAF lines, 30 haplotypes, 88.98 G query bases, 23 872 861 I/D operations (mismatches X do not break a
coordinate block). Per haplotype: ~0.8 M gap-free blocks. Calculation (not a measurement): 465 haplotypes ~ 370 M
blocks; at 16 B per block (ref start, hap start, length, contig id + strand) ~ 6 GB for all, ~13 MB per haplotype - of
the order of one refrel3 archive per assembly.

## 3. Plan of a prototype (not started)

- Index build (offline, CPU): per haplotype, from the PAF records of the chosen reference: gap-free blocks (ref contig,
  ref start, hap contig, hap start, length, strand), sorted by (ref contig, ref start); overlapping alignments of one
  haplotype (duplications) kept, marked; written as one binary file per haplotype + its SHA-256, next to the v1 archives.
- Query `fetch_ref(ref_contig, start, end)`: for every haplotype, binary search of the first block with ref end > start
  (an interval tree / sorted arrays with max-end per node to handle overlaps), walk to end, map each overlapping block
  to hap coordinates (minus strand: reverse-complement fetch), then the existing `fetch` of the archive. Result: up to
  558 answers with their mapping (hap contig, start, end, strand, fraction of the ref interval covered); unmapped parts
  reported, not filled.
- GPU: the block arrays resident like the archives; one thread block per (haplotype, query) does the search; the bytes
  come from the existing queue kernel. CPU path the same search.
- Truth for a test: for a set of ref intervals, the PAF CIGAR itself (independent re-walk in Python) gives the expected
  hap intervals; bytes then == the source FASTA at those intervals.
- Open questions: year-1 coverage (HAL 84 GB or own alignment); which reference first (CHM13 matches our archives'
  reference); multiple / partial alignments policy (report all, never pick silently).
