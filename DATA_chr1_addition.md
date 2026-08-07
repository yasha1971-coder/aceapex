## Genome assembly input (Paper 5 bounded-latency: latency spikes)
```
File:      chr1.fa (human chromosome 1, UCSC hg38 assembly)
Source:    https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/chr1.fa.gz
           (gunzip after download)
Size:      ~254 MB (253,935,557 bytes uncompressed)
Use:       Paper 5 bounded-latency — per-block seek-latency spikes on k-mer-dense
           soft-masked repeat regions (cluster ~blocks 7590-7770); depth-cap equalization.
Note:      UCSC hg38 uses soft-masking (lowercase = RepeatMasker/Tandem Repeats Finder
           regions). Latency spikes correlate with LOW k-mer uniqueness in these regions,
           NOT with soft-mask fraction per se (verified: 81% soft-mask block = normal
           latency, 98% = spike; the driver is k-mer duplication -> long LZ-chains).
```

To verify the exact file:
```bash
# md5 of the specific UCSC hg38 chr1.fa used (compute after gunzip):
md5sum chr1.fa
# The download is versioned by UCSC; pin to hg38 goldenPath chromosomes/chr1.fa.gz.
```

## Reproduction of bounded-latency (Paper 5)
See `reproduce_bounded_latency.sh`: scans per-block seek latency across chr1 + proteins
(spike-bearing) and fastq + dna200 (flat controls), reports spike frequency (~1%),
verifies k-mer-uniqueness cause on spike blocks, then shows depth-cap (aggressive
min_match) eliminates the spike (462->185us) while preserving median (184->184.6us) at
+1.28% size. Judge = bit-perfect FNV round-trip (v7-RA prints MATCHES). Requires v7ra
built from `e2e_seek.cu`.
