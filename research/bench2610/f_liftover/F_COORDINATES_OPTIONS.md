# F - reference -> haplotype coordinate translation for the 558: three options (text; one input measured)

Status 2026-10-07. Measured here: what the RLZ copies of our own archives give as a map (option 1), on two real
archives. Options 2 and 3 were NOT run; their sizes come from L1_LIFTOVER_SOURCES.md (Content-Length, one 300 MB
streamed sample of the CHM13 PAF). "Accuracy" of option 1 against an alignment is not measured yet (method below).

## Measurement of option 1 (chainstat)

`chainstat <ref.fa> <archive>` (this directory; build: `bash build.sh <dir>`, refrel3v1.cpp @ 5b6d5ce, binary SHA-256
b0c33493...): decodes every block's ops, puts every ref / rc copy at its absolute haplotype position, merges consecutive
copies on one diagonal (drift <= 64, hap gap <= 1 000, same hap contig, same ref chromosome) into chains.
Reference T2T-CHM13v2.0 (`~/golden/genome/t2t.fa`, decoded SHA-256 a6e4a745...). Outputs: `*.chainstat.txt`.
Reproduce: `bash build.sh D && D/chainstat ~/golden/genome/t2t.fa .wk/hprc_cohort/v1/<name>.q16k.rr3`.

| | r2_HG00097_hap1 (q16k, SHA-256 41af97fa...) | y1_HG00438.1 (q16k, c3f6999a...) |
|---|---:|---:|
| hap bases / contigs | 3 034 131 346 / 75 | 3 025 118 465 / 276 |
| bases by ref copy / rc copy / self / literal | 0.9761 / 0.0129 / 0.0094 / 0.0015 | 0.4572 / 0.5312 / 0.0100 / 0.0016 |
| copies (ref + rc); length p50 / p90 / p99 | 4 144 737; 209 / 1 612 / 9 406 | 4 475 312; 203 / 1 537 / 7 916 |
| chains; N50 | 1 276 607; 36 825 | 1 398 717; 32 091 |
| hap bases in chains: all / >= 10 kb / >= 100 kb | 0.9916 / 0.7914 / 0.2360 | 0.9913 / 0.7784 / 0.1882 |
| copied bases on the dominant ref chromosome of their hap contig | 0.9862 | 0.9857 |
| index at 24 B per chain | 30.6 MB | 33.6 MB |
| time / peak RSS (reference loaded) | 15.8 s / 6.1 GB | 16.2 s / 6.1 GB |

## Options

1. **Chains from our RLZ copies** (no external data). Accuracy: base-exact inside a copy (the copy is an exact match of
   the reference bytes); ~99.2 % of hap bases are in some chain, ~78-79 % in chains >= 10 kb; 1.4 % of copied bases sit
   on a non-dominant chromosome - copies are chosen for compression, not orthology, so in segmental duplications and
   repeats a copy can point to a paralog. Unknown until compared with an alignment. Memory: 31-34 MB per haplotype at
   24 B per chain -> ~18 GB for 558 (delta-coded ~1/3 of that, not built). Query: per haplotype a binary search over the
   chains sorted by ref position (log2 1.3 M ~ 21 steps), 558 searches per region - microseconds per haplotype on CPU,
   then the existing fetch. Covers all 558 (year-1 included), same reference build as the archives.
2. **Liftover chain from the published release-2 PAF** (wfmash, `cg:Z` CIGAR -> UCSC chain, liftOver / CrossMap
   semantics). Accuracy: that of a whole-genome alignment (orthology-aware chaining, indels explicit); the reference
   answer the field uses. Memory: ~0.8 M gap-free blocks per haplotype (streamed sample) -> ~10-13 MB per haplotype,
   ~5-6 GB for 465. Query: same binary-search cost as option 1. Covers the 464 `r2_` assemblies only; the 94 year-1 need
   the release-1 HAL (84 GB, hal2paf) or our own alignment. Download 5.6 GB (CHM13 PAF, gz).
3. **impg over the PAF / trace-point TPA** (pangenome-native queries, transitive through other haplotypes). Accuracy: as
   option 2, plus queries between any two haplotypes. Memory: interval index of alignment records only (~14 k records per
   haplotype in the sample - small); CIGAR / trace points read from disk per query (5.6 GB PAF or 25 GB TPA on disk).
   Query: index lookup + CIGAR walk or trace-point re-alignment per overlapping record - not measured; expected well
   above option 1/2 per region but no RAM cost. Coverage as option 2. External tool (Rust), not in our decoders.

## Recommendation

Use option 2 as the reference map and the truth: build per-haplotype gap-free block arrays from the release-2 CHM13 PAF
for the 464 `r2_` assemblies (one-off 5.6 GB download, ~5-6 GB resident, same O(log n) query as a fetch already pays).
Before relying on option 1 anywhere, measure it against option 2 on the 464: for N random ref intervals, the share whose
RLZ-chain answer equals the PAF answer (same hap contig, strand, start/end within a tolerance), reported separately in
segmental duplications. Option 1 then fills only the 94 year-1 assemblies, and only if that agreement is high enough to
state as a number; otherwise those 94 stay "assembly coordinates only" until an alignment exists. Option 3 is worth it
only if haplotype-to-haplotype queries become a goal; it adds a tool and disk-bound queries without adding coverage.
