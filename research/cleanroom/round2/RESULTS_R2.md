# RESULTS_R2 — refrel3 v1 clean-room implementation, round 2

Implementer inputs: /home/claude/cr2/pkg/refrel3_cleanroom_v2/ only. Outputs: /home/claude/cr2/work/.
decoder.py sha256 31f859bb2784adb46909a301187794304f5ff354a0158bae9abd5801674c190e
run_tests.py sha256 497840402be8eaa606242c3ceba13604d767bbc6e59ef3f7f6968887c20e2c79

## Package integrity

`sha256sum -c SHA256SUMS`: 67/67 entries OK (spec, EXPECTED.json, TEST_VECTORS.json, 26 archives,
9 corrupt archives, 26 fetch TSVs, 3 reference FASTAs). SHA256SUMS itself is not covered (cannot be).

## Counts

| test | result |
|---|---|
| a) full decode, sha256 + byte length of FASTA | **26 / 26** |
| b) fetch rows (sha256 of returned bases) | **1300 / 1300** (26 TSVs × 50 rows) |
| c) corrupt archives: refused, right stage, right reason, nothing written | **9 / 9** under the matching rule below; exact-string **4 / 9**, see below |
| d) test vectors (4 fixtures, 372 compared fields incl. rANS traces) | **372 / 372 match**, 0 mismatches, 0 fields left uncompared |

Corrupt-archive detail (all refused; stage correct 9/9; output_written false 9/9 — no output file exists):

| archive | my stage / message | expected | reason |
|---|---|---|---|
| truncated | open / refused: section sizes | open / same | exact |
| header_byte | open / refused: block count | open / same | exact |
| valid_for_wrong_reference | open / refused: reference SHA-256 / size differs (wrong reference) | open / same | exact |
| fasta_xxh3_field | decode / FASTA XXH3 differs from the header | decode / same | exact (wording from EXPECTED, see gap G2) |
| block_with_hash | decode / block decode failed (block 182: stream exhausted) | decode / block decode failed | prefix + detail (G2) |
| block_hash_byte | decode / block XXH3 mismatch (block 5) | decode / block XXH3 mismatch | prefix + detail (G2) |
| blocks_swapped | decode / block XXH3 mismatch (block 64) | decode / block XXH3 mismatch | prefix + detail (G2) |
| zero_context | decode / block decode failed (block 0: symbol with frequency 0 (context 59)) | decode / block decode failed | prefix + detail (G2) |
| meta_two_frames | open / refused: meta frame (meta section is not exactly one zstd frame) | open / refused: meta frame count (exactly one zstd frame) | **category only** — spec has no reason string for this check (G1) |

Matching rule for "right reason": my message equals the expected one, or starts with it (I append a
parenthesised detail), or the expected message starts with my §5 reason name. Strictly by exact string,
4/9 match; by "expected message is a prefix of mine", 8/9; meta_two_frames matches only by category.
Note: the decode-stage wordings were chosen after reading EXPECTED.json because §15 defines none (G2), so
those matches show category agreement, not that the spec determines the string.

## Test vectors (d)

Compared per fixture: all header fields (incl. header_xxh3 recomputed), meta (records, lower-case runs count
and first runs, 61 context sums, frequency count / nonzero count / sha256 of u16le frequencies, context 31
and context 0 frequencies, first block-table entries, meta frame first bytes), first block XXH3 values, full
decode (bytes, sha256, xxh3), and for every listed block: blen, stream offset/length/first bytes, start
diagonal, rANS init state, first 65 rANS events (symbol ctx/sym/state/pos and raw-bit fields), state after
symbol 1,2,4,…,64, symbol and raw-field counts, final state and bytes consumed, first events and first 16
copies (kind, offset, length, ref_start, strand, diagonal, cache after), output first 64 / sha256 / xxh3.
Fixtures: asmB.q16k.hash (69/69), asmC.q4k.hash (117/117), asmD.q4k.hash (85/85), asmG.q4k.hash with
reference_abs.fa (101/101). Covered kinds: CONT, DELTA, REP, ABS, SELF, FLIP, reverse-complement, escaped
literals. Test vectors were not needed to make anything work: the first run of the decoder passed a)–d).

## Failures

None in a), b), d). In c) no refusal failed; the only non-exact reason is meta_two_frames (G1), and the
decode-stage wordings depend on G2.

## Spec gaps

See SPEC_GAPS_R2.md: 0 blocking, 9 non-blocking (G1–G9), 2 remarks.

## Time

Wall clock from first command to finished reports ≈ 4 minutes of tool time (epoch 1791369327 → ~1791369560;
model thinking/writing time between tool calls is included in that span only partially). Test harness run
time (26 full decodes, 1300 fetches, 9 corrupt, 4 fixtures): 1.84 s.

## Libraries

Python 3.11.15 standard library (hashlib.sha256, struct, os, json). `zstandard` 0.25.0
(get_frame_parameters for the content size / dictionary id; ZstdDecompressor().decompressobj() with
.eof / .unused_data to decompress the meta and detect bytes after the first frame). `xxhash` 4.0.1
(xxh3_64_intdigest, seed 0). Both were already installed; nothing was pip-installed.

## Files read

- /home/claude/cr2/pkg/refrel3_cleanroom_v2/FORMAT_V1_SPEC.md (in full)
- EXPECTED.json (in full), SHA256SUMS (via sha256sum -c and first lines), TEST_VECTORS.json (structure,
  "about", field formats and a few sample entries were printed; then compared programmatically)
- archives/*.rr3, corrupt/*.rr3, reference/*.fa — read only by sha256sum and by decoder.py / run_tests.py
  (no manual byte inspection / hex dumps of archives)
- fetch/*.tsv — first 3 lines of one printed; all read by run_tests.py
- Directory listings of /home/claude/cr2/pkg and /home/claude/cr2/work. Nothing outside /home/claude/cr2 was
  read, apart from the Python interpreter importing the installed zstandard/xxhash packages.
