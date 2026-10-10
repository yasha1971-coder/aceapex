# FORMAT_V1_SPEC.md 1.0 -> 1.0.1 (editorial; bytes unchanged) and clean-room package v2.1

Input: round2/SPEC_GAPS_R2.md (sha256 22d493f6...), spec 1.0 = v2/FORMAT_V1_SPEC.md (b1799c30...).
Output: v2_1/FORMAT_V1_SPEC.md 1.0.1 (bab1065d...), v2_1/EXPECTED.json v2.1 (c75ab2ca...), package
refrel3_cleanroom_v2_1.zip (ce1e616a..., 2 263 838 B, two builds identical). No archive byte, encoder, format field or
validity rule changed; the 65 fixture files of the package are byte-identical to package v2. Section numbers §0–§19 are
unchanged; new: §5 step 0, §5 step 12a, §20 (reason summary), §21 (notes on the v1 reader), changelog.

Code references: `refrel3v1.cpp` = research/refrel/refrel3v1.cpp @ 5b6d5ce (the first v1 reader, frozen; binary sha256
b7d1842d... from research/cleanroom/repro.sh); `refrel_io.h`, `refrel3.h`, `refrel_format.h` = research/refrel @ 5b6d5ce
(unchanged since); `pv_v1.h` = ~/panvram csrc/pv_v1.h @ 087c638 (the v1 reader revision that adds the two checks the
spec already had in 1.0: one meta frame, all-zero context). Behaviour on cases outside the package: `edge_checks.py`,
18/18 as stated (output below).

| gap | 1.0 (before) | 1.0.1 (after) | code |
|---|---|---|---|
| G1 one zstd frame | §4 "exactly one zstd frame"; §5 steps 12–13 only content size and decompressed size; no step, no reason | §5 step 12a `meta frame count`: first frame's compressed size (header, blocks to Last_Block, checksum) = meta_bytes; trailing frame (empty too), skippable frame, other bytes, truncated frame all fail 12a; skippable frame first: step 12 (content size 0); numbering kept by "12a" | pv_v1.h:119 `ZSTD_findFrameCompressedSize(mzp, mz) != mz` -> "meta frame count (exactly one zstd frame)" (normative reason = `meta frame count`, the rest is a detail under the §5 rule). refrel3v1.cpp:96–97 has no such step: it accepts an appended empty or skippable frame and reports garbage / truncation as `meta decompress` (§21) |
| G2 decode-stage reasons | §15 conditions only, no strings | §5 normative-reason rule (stage + exact reason, optional ` (detail)`); §13/§15 reasons `block`, `block XXH3`, `FASTA XXH3`; `block` before `block XXH3` within a block, block checks before `FASTA XXH3`, any invalid block's reason if several (parallel) | refrel3v1.cpp:154 `decode failed (%s)` with "block" / "block XXH3" / "FASTA XXH3"; :125 (k < 0 -> 1), :127 (hash -> 2), :139 (FASTA -> 3), :133–134 (threads, first error by compare-exchange) |
| G3 reference outside §3.1 | §3.1 "applies to the reference", only the encoder refuses | §3.1 "Reader side" + §5 step 0: refuse before reading the archive, reasons `no header`, `no final line end`, `irregular line layout`; tolerance: last header line without LF (no base, same R) MAY be accepted; unreadable reference: reason not normative | refrel3v1.cpp:31–32 load_ref -> read_fasta, called first (:151, :166); refrel_io.h:27, :33, :35–36 (messages, exit 2); header-without-LF tolerance = refrel_io.h:28–29 (header taken up to the end of the file) |
| G4 "records / contig table" | one bracket with a slash | two distinct reasons: `records` iff nrec > meta_raw (u32 alone, before records), `contig table` for overrun, len > 0 with lw = 0, Σ len ≠ n | refrel3v1.cpp:103 ("records"), :104–105 ("contig table") |
| G5 modulus of sums | not stated | §0: size / count arithmetic exact (unbounded); only §4.4 diagonals mod 2^64 and §9–§10 int64; §21: the first reader computes in u64 — equal to exact for steps 7, 8; can wrap in steps 14, 15, 17 only for field values no encoder writes | refrel3v1.cpp:88–90 (step 7 bounds each field <= file size first; step 8 `(X.nbases && !X.nb)` catches the ceil wrap), :104 `bo += q.len`, :107 `lst + g + l`, :114 `X.off[b] + len` (u64); pv_v1.h:139 `len > pl - acc` (exact for step 17) |
| G6 dictionary / frame parameters | §4 "no dictionary"; not an open check | §4 / §5 step 13: nonzero Dictionary_ID fails `meta decompress`; content checksum allowed, verified, mismatch = `meta decompress`; no content size / unparsable header = `meta frame` | refrel3v1.cpp:96 `ZSTD_getFrameContentSize` (unknown / error != meta_raw), :97 `ZSTD_decompress` without a dictionary: libzstd 1.4.8 returns "Dictionary mismatch" for Dictionary_ID 7, "Restored data doesn't match checksum" for a wrong checksum (edge_checks.py) |
| G7 invalid fetch | §14 validity condition only | §14 table, stage `fetch`: `no contig`, `bad range` (outside 0 <= start0 < end0 <= len, zero / negative length, any request on a length-0 record), `block` for a failed touched block (rANS or block XXH3); per-request; v1 reader continues after `no contig` / `bad range`, stops the call after `block` | refrel3v1.cpp:171 "no contig %s", :173 "bad range %s" (`s1 < 1 \|\| e1 > R.len \|\| s1 > e1`), :175 "block %llu failed" + return 3 (verify = true) |
| G8 4096 limit | §11 "limits a block to 4096 events' worth of operations"; not in §15 | §11: bound 2·floor(blen/13) + (blen mod 13 > 0) = 2 521 for Q = 16 384, for any stream; the 4096 array is never reached, not a check, no reason, MUST NOT refuse for it; literal bytes <= blen <= Q | refrel_format.h:31 `RR_MAXOPS 4096u`; refrel3.h:128 (one op per non-empty literal run, after `ll <= blen - o`), :150 (one op per copy, after `L <= blen - o`, L >= 12), :158 (capacity -> -1) |
| G9 bases_xxh3 | "MAY verify ... and refuse"; no stage / reason | §12.4: only in a full decode, after `FASTA XXH3`; stage `decode`, reason `bases XXH3`; never on fetch; not emitted by the v1 reader, not used by any fixture; not checking it is fully conforming | refrel3v1.cpp:85 reads `bases_xxh`, never compared (no use after :85); covered by header XXH3 (:92) |

Not gaps (remarks R1, R2 of SPEC_GAPS_R2.md): no change. The two 1.0 statements stricter than the first v1 reader (one
meta frame; all-zero context fails at once) are kept and now listed in §21 together with the u64 sums of steps 14, 15, 17.

## EXPECTED.json v2.1

Same "archives" (26) and fetch tables as v2. For each of the 9 refusal fixtures `reader_response` is now
`{stage, reason, message, output_written: false}` with `reason` = the normative string and `message` = `refused: <reason>`
or `decode failed (<reason>)`; new top-level keys `expected_version` = "2.1", `refusal_reasons` (the matching rule).
Derived by `make_expected_v2_1.py` from the actual output of the first v1 reader (v1_reader_responses.tsv):

| fixture | v2 message | v2.1 stage / reason | first v1 reader (stderr, exit) |
|---|---|---|---|
| truncated | refused: section sizes | open / `section sizes` | refused: section sizes, 2 |
| header_byte | refused: block count | open / `block count` | refused: block count, 2 |
| valid_for_wrong_reference | refused: reference SHA-256 / size differs (wrong reference) | open / `reference SHA-256 / size differs` | refused: reference SHA-256 / size differs, 2 |
| meta_two_frames | refused: meta frame count (exactly one zstd frame) | open / `meta frame count` | accepted, FASTA written, 0 (no step 12a, §21) |
| block_with_hash | block decode failed | decode / `block` | decode failed (block), 3 |
| zero_context | block decode failed | decode / `block` | decode failed (block), 3 |
| block_hash_byte | block XXH3 mismatch | decode / `block XXH3` | decode failed (block XXH3), 3 |
| blocks_swapped | block XXH3 mismatch | decode / `block XXH3` | decode failed (block XXH3), 3 |
| fasta_xxh3_field | FASTA XXH3 differs from the header | decode / `FASTA XXH3` | decode failed (FASTA XXH3), 3 |

8/9 equal to the first v1 reader's reason; meta_two_frames: reason of step 12a (pv_v1.h:119), that reader accepts it.

## Package v2.1 and checks

- `build_pkg_v2_1.py <v2 package dir> <out>`: v2 package checked against its SHA256SUMS; fixtures copied (65/65
  identical to v2), FORMAT_V1_SPEC.md 1.0.1, EXPECTED.json v2.1, README_TASK.md; SHA256SUMS (68 lines); internal-name
  grep 0; spec decoder `specdec.py` (v2.1: reasons of §20, step 12a by frame walk, step 0) on the package: decode 26/26,
  fetch 1 300/1 300, refused with the expected stage and reason 9/9; ZIP sorted, mtime 2026-10-08 00:00:00 UTC, modes
  644 / 755, `zip -X`. Two builds into separate directories: both ce1e616ae4e55696426969409201e36774d6962be062eec28414470442e5acfe.
- `edge_checks.py`: 18/18 — meta + empty frame (first reader accepts; 1.0.1 `meta frame count`), + skippable frame
  (accepts; `meta frame count`), + 9 garbage bytes (`meta decompress`; `meta frame count`), truncated by 3 B (`meta
  decompress`; `meta frame count`), skippable frame first (`meta frame` both), Dictionary_ID 7 (`meta decompress` both),
  valid checksum (accepted both), wrong checksum (`meta decompress` both), meta_raw + 1 (`meta frame` both), nrec =
  meta_raw + 1 (`records` both); reference blank first line / no final LF / empty sequence line (`no header` /
  `no final line end` / `irregular line layout` both), + header without LF (accepted both); fetch unknown name (`no
  contig` both), end beyond record, zero length, start 0 in 1-based form (`bad range` both).
- `reconcile_r2.sh <unzipped v2.1> <work>`: the round-2 decoder unchanged on package v2.1: decode 26/26, fetch
  1 300/1 300, vectors 372/372; refusals 9/9 refused at the right stage with nothing written; reasons 4/9 by its own rule,
  3/9 by the 1.0.1 rule — the six differences are the wordings it had to guess under G1 / G2 (`block decode failed`,
  `block XXH3 mismatch`, `FASTA XXH3 differs from the header`, `meta frame (...)`), which 1.0.1 now fixes.

## Reproduce

```
W=~/pubrepo/.wk/repro_g1c                                    # research/cleanroom/repro.sh work dir (refrel3v1, xxh3_stdin)
V2=<unzipped refrel3_cleanroom_v2.zip, sha256 291ae64d...>/refrel3_cleanroom_v2
python3 research/cleanroom/v2_1/make_expected_v2_1.py $V2 $W/refrel3v1          # EXPECTED.json v2.1, 9/9
XXH3_BIN=$W/xxh3_stdin python3 research/cleanroom/v2_1/build_pkg_v2_1.py $V2 <out1>   # and again into <out2>: same sha256
XXH3_BIN=$W/xxh3_stdin python3 research/cleanroom/v2_1/edge_checks.py <out1>/refrel3_cleanroom_v2_1 $W/refrel3v1 <tmp>
bash research/cleanroom/v2_1/reconcile_r2.sh <out1>/refrel3_cleanroom_v2_1 <new work dir>
```
