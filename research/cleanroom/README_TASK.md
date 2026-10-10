# Task

Write a decoder for the archive format specified in `FORMAT.md` (refrel3 v1), working only from that specification and
the files of this package. Language and design are your choice.

## Inputs

- `reference/reference.fa` - the reference FASTA every archive was encoded against.
- `reference/reference_wrong.fa` - a reference that differs from it.
- `archives/*.rr3` - 24 archives (6 assemblies x block size 4096 / 16384 x with / without per-block hashes).
- `corrupt/*.rr3` - 7 damaged or mismatched cases (truncation, header byte, payload byte, wrong reference, stored block
  hash changed, source-FASTA hash field changed, two blocks swapped).
- `fetch/<archive>.fetch.tsv` - 50 region requests per archive: `contig`, `start`, `length`, `sha256`.
- `EXPECTED.json` - every expected value; `SHA256SUMS` - the SHA-256 of every file of the package (relative paths).

## What the decoder must do

1. Full decode: given an archive and a reference, produce the original FASTA file (headers, line breaks, letter case),
   byte for byte.
2. Region fetch: given an archive, a reference, a contig name (the FASTA header up to the first space or tab), a 0-based
   start and a length, produce exactly those bases of that contig, letter case as in the original, without line breaks.
3. Refusal: when the archive is damaged, truncated, does not belong to the given reference, or fails any check the
   specification requires, report an error and produce no output (no partial FASTA, no region bytes).

## How it is checked

- For every entry of `EXPECTED.json` "archives": SHA-256 of the full decoded FASTA == `fasta_sha256` (and the byte count ==
  `fasta_bytes`); for every row of its fetch table: SHA-256 of the returned bases == `sha256`.
- For every entry of "corrupt": a full decode with the listed reference reports an error and writes no output.
- A run passes only if all 24 full decodes, all 1 200 fetch answers and all 7 refusals match. Any crash, hang (allow at
  most 60 s per archive) or output on a refusal case is a failure.
- First verify the package itself: `sha256sum -c SHA256SUMS` from the package root.
