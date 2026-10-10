# Task

Write a decoder for the archive format specified in `FORMAT_V1_SPEC.md` (refrel3 v1, document version 1.0.1), working
only from that specification and the files of this package. Language and design are your choice.

## Inputs

- `FORMAT_V1_SPEC.md` - the byte-level specification (self-contained).
- `reference/reference.fa` - the reference FASTA most archives were encoded against; `reference/reference_wrong.fa` - a
  reference that differs from it; `reference/reference_abs.fa` - the reference of the two `asmG` archives.
- `archives/*.rr3` - 26 archives (6 assemblies x block size 4096 / 16384 x with / without per-block hashes, and asmG
  block size 4096 with / without per-block hashes, which uses absolute-position copies).
- `corrupt/*.rr3` - 9 damaged or mismatched cases.
- `fetch/<archive>.fetch.tsv` - 50 region requests per archive: `contig`, `start` (0-based), `length`, `sha256`.
- `EXPECTED.json` - every expected value; `TEST_VECTORS.json` - intermediate values (header, meta, rANS events, copies)
  of four archives, for debugging; `SHA256SUMS` - the SHA-256 of every file of the package (relative paths).

## What the decoder must do

1. Full decode: given an archive and a reference, produce the original FASTA file (headers, line breaks, letter case),
   byte for byte.
2. Region fetch: given an archive, a reference, a contig name (the FASTA header up to the first space or tab), a 0-based
   start and a length, produce exactly those bases of that contig, letter case as in the original, without line breaks.
3. Refusal: when the archive is damaged, truncated, does not belong to the given reference, or fails any check the
   specification requires, report the stage and the reason string defined by the specification (sections 5, 15, 20) and
   produce no output (no partial FASTA, no region bytes).

## How it is checked

- First verify the package itself: `sha256sum -c SHA256SUMS` from the package root.
- For every entry of `EXPECTED.json` "archives": SHA-256 of the full decoded FASTA == `fasta_sha256` (and the byte count
  == `fasta_bytes`); for every row of its fetch table: SHA-256 of the returned bases == `sha256`.
- For every entry of "corrupt": a full decode with the listed reference is refused at `reader_response.stage` with the
  reason `reader_response.reason` (exact string, or the string followed by ` (` and a detail; specification section 5),
  and writes no output.
- A run passes only if all 26 full decodes, all 1 300 fetch answers and all 9 refusals (stage and reason) match. Any
  crash, hang (allow at most 60 s per archive) or output on a refusal case is a failure.
- Report every place where the specification was unclear, incomplete or contradicted the files, with the section
  number, separately from the results.
