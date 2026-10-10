# SPEC_GAPS_R2 — refrel3 v1 clean-room round 2

Spec: FORMAT_V1_SPEC.md (sha256 b1799c30814e670856f2552cda003d822c162c3865c3e2eb6c8a4552b336ca71).
Ranking: blocking first. **Blocking gaps: 0.** Non-blocking gaps: 9 (G1–G9), plus 2 remarks.
No test vector was needed to resolve any spec question: the decoder matched every archive, fetch and
test vector on its first run; TEST_VECTORS.json was used only for verification afterwards.

## Blocking

(none)

## Non-blocking

**G1 — §4 / §5: "exactly one zstd frame" has no open-check step and no reason string.**
§4 says the meta section "is exactly one zstd frame" and the parser must end at meta_raw, but §5 steps 12–13
only check the frame header's content size and that decompression yields meta_raw bytes. A second frame
(or any bytes after the first frame) appended inside meta_bytes passes both steps as written if a
decompressor stops after the first frame. Not stated: whether this is checked, at which step, and with which
reason; whether trailing non-frame garbage is "meta frame" or "meta decompress"; whether skippable frames count.
Assumed: checked at step 13 (after decompressing the first frame, any unused byte in the section → refuse),
reason "meta frame" (step 12's name). EXPECTED.json uses a different string, "meta frame count (exactly one
zstd frame)", which the spec never mentions — so the reason of corrupt/meta_two_frames.rr3 matches only at the
category level ("meta frame…"), not as an exact string. Did not block.

**G2 — §15: no reason strings for decode-stage refusals.** §5 gives a reason for every open check; §15 gives
only the list of conditions. The three decode-stage categories (rANS/grammar failure, block XXH3 mismatch,
FASTA XXH3 mismatch) follow from §15/§13, but the wording does not. Assumed/used: "block decode failed",
"block XXH3 mismatch", "FASTA XXH3 differs from the header" — this wording was taken from EXPECTED.json
(declared here, since the spec does not provide it); my messages append a detail in parentheses. Did not block.

**G3 — §3.1 / §5 step 11: reader behaviour for a reference FASTA that violates §3.1 (or cannot be read) is
not specified.** §3.1 says layout "applies to the reference"; §3.1 end only says the *encoder* refuses other
layouts. Not stated: must a reader refuse such a reference, or concatenate bases leniently; at which step;
with which reason. Assumed: strict parse, refuse at open with "reference FASTA layout (…)" before step 11's
comparison. Not exercised by the package (all three references are well-formed). Did not block.

**G4 — §5 step 14 reason "records / contig table":** unclear whether this is one reason string or two
alternatives ("records" for nrec/len/lw/Σlen vs "contig table" for parse overrun). Assumed one string. Not
exercised. Did not block.

**G5 — §5 step 7 arithmetic width.** `payload_start = 138 + L + meta_bytes + hash_bytes` and
`payload_start + payload_bytes` are sums of u64 fields; not stated whether they are computed exactly or modulo
2^64 (a C reader wrapping could accept huge fields that sum to the file size). Assumed exact (unbounded)
arithmetic, which refuses wrapped values. Not exercised. Did not block.

**G6 — §4 "no dictionary" and frame parameters are not an open check.** §4 states "no dictionary", §5 step 12
only checks content size. Assumed: a nonzero dictionary ID in the frame header → refuse "meta frame".
Not exercised. Did not block.

**G7 — §14: refusal stage/reason for an invalid fetch request** (unknown record name, interval not satisfying
0 ≤ start0 < end0 ≤ len) is not specified. Assumed stage "fetch", reasons "unknown record name" /
"invalid interval". Not exercised by the TSVs (all rows valid). Did not block.

**G8 — §11 4096-operation limit vs §15.** §11 says the v1 reader limits a block to 4096 events' worth of
operations, but §15 (the complete list of decode checks) does not list it and gives no reason. With Q ≤ 16384
and every non-final copy ≥ 12 bases the limit is unreachable (≤ ~2731 operations), so it was not implemented.
Did not block.

**G9 — §12.4 bases_xxh3 optional check: reason string and stage not given** ("MAY verify ... and refuse").
Not implemented (the v1 reader does not check it). Did not block.

## Remarks (not gaps)

- R1. §8 defines `refbase(o)` with a generic "block offset o"; §17 makes it explicit that the literal's own
  offset `o + j` is used. Consistent; I followed §17.
- R2. Trace format used for comparison (one 'bits' event per raw field, not per 16-bit chunk; state-after-N
  counts only decode_symbol calls; XXH3 hex = `%016x` of the u64) comes from TEST_VECTORS.json's own
  description or, for the state-after-N counting, from reading the vector's values; it is not in the spec
  and affects only the harness, not decoding.
