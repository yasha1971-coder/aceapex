# Clean-room package v2 - FORMAT_V1_SPEC.md against SPEC_GAPS.md (round 1)

Package (not published): `/home/aeterna/outgoing/refrel3_cleanroom_v2.zip`, SHA-256
291ae64d1ca43745f4063b49d5c2b310dc34bae3e701ec2147b4737ffc87bfb6, 2 257 720 B, 68 files + 5 directory entries. Built twice
from nothing to the same bytes (sorted entries, mtime 2026-10-07 00:00:00 UTC, zip 3.0 -X). Input: SPEC_GAPS.md SHA-256
d991f3e8f7858115f324486a61bc9e4c43e0300530039f70c0872e134819cf25. (First build of the day without the A5 additions:
3aad8134..., superseded.)

Contents: FORMAT_V1_SPEC.md, TEST_VECTORS.json (4 fixtures), EXPECTED.json, SHA256SUMS; reference/ (reference.fa,
reference_wrong.fa, reference_abs.fa), archives/ (26: the 24 of v1 + asmG.q4k hash / nohash with ABS copies), corrupt/
(9: the 7 of v1 + zero_context, meta_two_frames), fetch/ (26 tables x 50). No task text (given separately). No sources,
no source or internal names: grep of the unzipped package for 21 patterns = 0 matches (control on the v1 FORMAT.md: 5 lines).

A5 additions:
- ABS fixture: `gen_abs.py` - reference_abs.fa of 19 000 000 bases (r1 1 M random, r2 17 M N, r3 1 M random: r3 lies
  > 2^24 from r1), asmG 200 000 bases copied alternately from r1 and r3; frozen encoder -> 45 ABS copies (also 112
  reverse-complement, 3 FLIP, 4 REP); frozen decode == source; spec decoder == source; ops == frozen code (604 / 604).
- Stricter checks, refusal fixtures (`make_strict.py`): zero_context.rr3 (asmB.q4k.hash, context 59 all zero; frozen
  reader: decode failed (block); spec reader: zero frequency) and meta_two_frames.rr3 (asmD.q16k.nohash + empty zstd
  frame of 9 B after the meta; frozen reader ACCEPTS and writes the FASTA; spec reader: refused, meta frame count).
- The v1 reader (panvram) carries both checks now; EXPECTED.json "reader_response" (stage, message) of all 9 refusals
  comes from it (`reader_responses.py`).

## Checks of the specification

| check | result |
|---|---|
| decoder written from FORMAT_V1_SPEC.md only (`specdec.py`, Python) on the package | 26/26 full decodes, 1 300/1 300 fetches, 9/9 refusals |
| its ops against the frozen v1 code, every block of the 24 + 2 archives (`opcmp.py`) | 92 938 + 1 208 ops, 0 differences |
| rANS events against a traced copy of the frozen code (`trace_check.sh`) | 14 blocks of 4 fixtures, 9 358 events, 0 differences; TEST_VECTORS.json == the trace |

TEST_VECTORS.json: asmB.q16k.hash (blocks 0, 1), asmC.q4k.hash (0, 2, 10, 14, 43), asmD.q4k.hash (0, 9, 20), asmG.q4k.hash
(0, 1, 3, 5; ABS) - block 0 and the first block with SELF, FLIP, reverse-complement copy, escaped literal, DELTA, REP, ABS.

## 25/25: every gap of SPEC_GAPS.md -> section of FORMAT_V1_SPEC.md

| # | gap | closed in |
|---:|---|---|
| 1 | model alphabet sizes | §8 table and list A_0..A_60 (Σ 1827), §4.3 |
| 2 | meaning / index of every context, order-2, out-of-range / N | §8 (context table, refbase, o2, kclass, llc), §17 |
| 3 | rANS coder: precision, init, renorm, direction, zero frequency | §6.1–§6.3 (decoder), §6.4 (encoder), §6.2 |
| 4 | final state | §6.1 (65536), §6.3 finish (state and position) |
| 5 | event grammar, large values, minimum length, kind values | §9, §7.1, §8 (kind symbols), §16 |
| 6 | kind semantics, diagonal, caches, reset, self, other strand | §10.1–§10.3, §11 (comp table) |
| 7 | block start state: c, zig-zag, whose strand, first block, seeding, name collision | §4.4 ("block start diagonal"), §7.2, §10.2 |
| 8 | literal alphabet, non-ACGTN bytes | §8 literal symbols (escape + 8 raw bits) |
| 9 | copies over N, bounds, reverse-strand bound | §10.3 checks, §11 |
| 10 | payload never encodes case | §3.3, §11, §12.2 |
| 11 | reference-name encoding | §2.2 |
| 12 | reserved field | §2.1, §5 step 6 |
| 13 | order of open checks | §5 (normative order with reasons) |
| 14 | header XXH3 coverage | §2.1 |
| 15 | XXH3 storage | §0 |
| 16 | reference decoding (N, case, CR, empty lines) | §3.1, §3.2 |
| 17 | meta frame requirements | §4, §5 steps 12–13 |
| 18 | contig table, line layout, empty record, terminators | §3.1, §4.1, §13 step 4 |
| 19 | fetch coordinates | §14 (canonical zero-based half-open; 1-based form mapped) |
| 20 | lower-case runs (base, empty, order, contig crossing) | §4.2 |
| 21 | block table interleaving | §4.4 |
| 22 | end of meta | §4 (no trailing bytes), §5 step 17 |
| 23 | mandatory checks, fetch checks, no-hash fetch | §14, §15 |
| 24 | base-stream XXH3 | §12.4 |
| 25 | external normative references | whole document self-contained: §6–§11, §17, §16; no file of the implementation named |

## Where the specification was stricter than the frozen v1 reader (now also checked by the panvram v1 reader)

- A symbol from an all-zero context: §6.3 fails at once. The v1 reader marks the stream bad and fails later at the next
  count / length or at the final-state check; a stream reaching such a context only inside a final long literal run
  could in principle still end with state 65536.
- Meta: §4 requires exactly one zstd frame; the v1 reader checks the first frame's content size and that decompressing
  all meta bytes yields meta_raw bytes.

## Reproduce

```
bash research/cleanroom/repro.sh <W>                       # v1 package, tool, data (zip 75ff3f60...)
PANVRAM_PY=~/panvram/.venv/bin/python XXH3_BIN=<W>/xxh3_stdin python3 research/cleanroom/v2/build_pkg_v2.py <W> <OUT>
bash research/cleanroom/v2/trace_check.sh <W> <OUT>/refrel3_cleanroom_v2/TEST_VECTORS.json <OUT>/work_abs
g++ -std=c++17 -O2 -I<W>/src/src -I<W>/src/research/refrel research/cleanroom/v2/opdump.cpp <W>/src/src/aceapex_api.cpp -lzstd -lpthread -o <W>/opdump
XXH3_BIN=<W>/xxh3_stdin python3 research/cleanroom/v2/opcmp.py            # W = ~/pubrepo/.wk/repro_g1c in opcmp.py
```
