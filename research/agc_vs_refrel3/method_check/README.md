# Method check (PROTOCOL_AGC558 section 3), N = 5, ace-core 2026-10-06

AGC 3.2.4 built from source (commit e67e3fc), `agc create -d -k 31 -l 20 -s 60000 -b 50 -t 16 -o <out> <T2T> <5 inputs>`,
inputs `in/<manifest name>.fa` for the first 5 manifest assemblies (`names5.tsv`; `.fa.gz` SHA-256 == the year-1 index):

| run | inputs | archive bytes | wall | peak RSS |
|---|---|---:|---:|---:|
| file1.agc | regular files (gunzip of the sources) | 798 568 656 | 65.99 s | 26 320 512 KB |
| file2.agc | same, again | 798 568 656 | 66.00 s | 26 460 752 KB |
| fifo.agc | the same paths as FIFOs fed by `fifo_feed` from the q16k v1 archives (every check on) | 798 568 656 | 76.26 s | 26 465 808 KB |

`archives.sha256`: file1 == file2 (AGC deterministic for these options) and fifo == file1 byte for byte: PASS.
`feed5.log`: every pipe served in full (bytes == the source FASTA sizes).
