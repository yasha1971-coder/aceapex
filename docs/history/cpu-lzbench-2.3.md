# CPU table of lzbench 2.3 (historical)

Moved from README.md on 2026-11-21. Measured with `aceapex 1.0.1` (format 1) as included in lzbench 2.3; not a
reading of the current version. Current numbers: [TurboBench](https://github.com/powturbo/TurboBench/blob/master/benchmark.md),
[lzbench](https://github.com/inikep/lzbench).

**Correction 2026-11-21:** the "3.65x faster" in the note below compared ACEAPEX `-T8` with one zstd thread; it is
withdrawn.

### CPU (lzbench 2.3, host-to-host, decompress MB/s)

| Dataset | CPU 1-thread | aceapex_cuda | CPU -T8 |
|---------|-------------|--------------|---------|
| FASTQ 1 GB (ERR194147) | 1,624 | 4,373* | 7,401 |
| enwik9 1 GB | 655 | 1,463 | 5,109 |
| silesia | 803 | 1,403 | 5,594 |

All results XXH3 bit-perfect verified.

*The FASTQ row was re-measured on ENA accession ERR194147 (md5 9af9ffaa0e15dba938408a711740e101);
the previously published figures (1,840 / 13,363 MB/s) came from a local sample with degenerate
quality strings. At ratio 3.98 versus zstd -3 at 3.96 on the same file, ACEAPEX -T8 decodes at
7,401 MB/s against zstd -3 at 2,026 MB/s: 3.65x faster at genuinely comparable ratio.
(*aceapex_cuda row not yet re-measured on the corrected file.)
