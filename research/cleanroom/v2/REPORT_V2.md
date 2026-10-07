# Clean-room package v2 - FORMAT_V1_SPEC.md against SPEC_GAPS.md (round 1)

Package (not published): `refrel3_cleanroom_v2.zip`, SHA-256 3aad8134ab663ed6f51864b1532be61a60542cb4e8f5a30fb35f13cdc2477144,
1 540 624 B, 62 files + 5 directory entries. Built twice from nothing to the same bytes (sorted entries, mtime
2026-10-07 00:00:00 UTC, zip 3.0 -X). Input: SPEC_GAPS.md SHA-256 d991f3e8f7858115f324486a61bc9e4c43e0300530039f70c0872e134819cf25.

Contents: FORMAT_V1_SPEC.md, TEST_VECTORS.json, README_TASK.md (the task text of v1, pointing to the specification and
the vectors), EXPECTED.json (v1 expected hashes; "tool_response" renamed "reader_response"), reference/ archives/
corrupt/ fetch/ byte-identical to package v1, SHA256SUMS. No sources, no source or internal names: grep of the
unzipped package for 21 patterns (source file names, identifiers, paths, project names) = 0 matches; the same grep
on the v1 FORMAT.md = 5 lines (control).

## Checks of the specification

| check | result |
|---|---|
| decoder written from FORMAT_V1_SPEC.md only (`specdec.py`, Python) on the package | 24/24 full decodes, 1 200/1 200 fetches, 7/7 refusals, the same refusal step as the v1 reader in all 7 |
| its ops (kind, source, offset, length) against the frozen v1 code, every block of the 24 archives (`opcmp.py`) | 92 938 ops, 0 differences |
| rANS events (context, symbol, state, position after each symbol / raw-bit field) against a traced copy of the frozen code (`trace_check.sh`) | 10 blocks of 3 fixtures, 9 186 events, 0 differences; TEST_VECTORS.json == the trace |

TEST_VECTORS.json: asmB.q16k.hash (blocks 0, 1), asmC.q4k.hash (0, 2, 10, 14, 43), asmD.q4k.hash (0, 9, 20) - block 0 and
the first block with SELF, FLIP, reverse-complement copy, escaped literal, DELTA, REP. Per fixture: header fields and
recomputed header XXH3, contig table, case runs, 61 context sums, frequency SHA-256, block table (stream bytes, start
diagonal), first block XXH3s, full-decode FASTA SHA-256 / XXH3; per block: first 8 stream bytes, init state, first 64
rANS events, states after 1/2/4/8/16/32/64 symbols, first 32 events and first 16 copies with ref start, strand, diagonal
and the cache after each, output head, output SHA-256 / XXH3.

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

## Where the specification is stricter than the v1 reader (crafted inputs only; no fixture and no valid archive affected)

- A symbol from an all-zero context: §6.3 fails at once. The v1 reader marks the stream bad and fails later at the next
  count / length or at the final-state check; a stream reaching such a context only inside a final long literal run
  could in principle still end with state 65536.
- Meta: §4 requires exactly one zstd frame; the v1 reader checks the first frame's content size and that decompressing
  all meta bytes yields meta_raw bytes.

## Fixture coverage note

No archive of the package contains an ABS copy (the encoder found every copy through CONT / DELTA / REP / FLIP from the
start diagonal); ABS is specified (§10.3, §17) but not exercised by the fixtures.

## Reproduce

```
bash research/cleanroom/repro.sh <W>                       # v1 package, tool, data (zip 75ff3f60...)
XXH3_BIN=<W>/xxh3_stdin python3 research/cleanroom/v2/build_pkg_v2.py <W> <OUT>
bash research/cleanroom/v2/trace_check.sh <W> <OUT>/refrel3_cleanroom_v2/TEST_VECTORS.json
g++ -std=c++17 -O2 -I<W>/src/src -I<W>/src/research/refrel research/cleanroom/v2/opdump.cpp <W>/src/src/aceapex_api.cpp -lzstd -lpthread -o <W>/opdump
XXH3_BIN=<W>/xxh3_stdin python3 research/cleanroom/v2/opcmp.py            # W = ~/pubrepo/.wk/repro_g1c in opcmp.py
```
