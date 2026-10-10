# refrel3 v1 — byte-level specification

Status: normative description of the existing refrel3 v1 archives (version field 1). It defines exactly the bytes the
v1 encoder writes and the behaviour of a conforming v1 reader; it changes nothing. This document is self-contained: no
other document or program is needed to decode an archive. Words MUST / MUST NOT / MAY are normative.

Document version **1.0.1** (2026-10-08): editorial release of 1.0. Archive bytes, the format and the set of valid
archives are unchanged; 1.0.1 states the refusal reasons, arithmetic and edge cases that 1.0 left implicit (changelog at
the end).

Contents: §0 conventions · §1 container layout · §2 header · §3 FASTA model (reference, assembly, case) · §4 meta ·
§5 open checks (ordered) · §6 entropy coder (rANS) · §7 integer coding (buckets, zig-zag, raw bits) · §8 contexts ·
§9 block grammar · §10 copy kinds and the diagonal cache · §11 block execution · §12 hashes · §13 full decode ·
§14 region fetch · §15 decode-time checks and refusal · §16 constants · §17 pseudocode of the block decoder ·
§18 encoder-side facts (non-normative) · §19 versioning · §20 refusal reasons (summary) · §21 notes on the v1 reader ·
changelog.

## 0. Conventions

- All multi-byte integers in the header and meta are **little-endian**, unsigned unless stated.
- `u16`, `u32`, `u64`: unsigned 2/4/8-byte little-endian integers.
- **LEB128** (unsigned): 7 data bits per byte, least significant group first, bit 7 = continuation. A reader MUST
  refuse a LEB128 that runs past the end of its buffer or needs more than 10 bytes (shift > 63). Values are 64-bit;
  bits beyond 64 are discarded (the encoder never produces them).
- **XXH3** = XXH3_64bits of xxHash 0.8 with seed 0 (the 64-bit XXH3 variant, no secret, no seed). A stored XXH3 is the
  64-bit digest written as a **u64 little-endian integer** (not the canonical big-endian byte form).
- **SHA-256** = FIPS 180-4, stored as its 32 digest bytes in the usual order.
- **zstd** = Zstandard frame format (RFC 8878).
- Intervals are half-open `[a, b)` unless stated. "Base" = one byte of sequence.
- Signed arithmetic in §9–§10 is two's-complement 64-bit; values written `int64` MAY be negative; `uint64` values
  stored in the diagonal cache are the two's-complement bit pattern of an int64 (§10.1).
- **Size and count arithmetic is exact.** Every sum, product, ceiling and comparison on sizes, counts, lengths and
  offsets in §1–§5, §13 and §14 (for example `payload_start`, `payload_start + payload_bytes`, `ceil(n / Q)`,
  `8 × nblocks`, Σ len, run ends, Σ slen) is computed on unbounded integers, not modulo 2^64. A check holds only if it
  holds for the exact values. The only modular arithmetic of v1 is the diagonal arithmetic of §4.4 (mod 2^64) and the
  int64 arithmetic of §9–§10.

## 1. Container layout

```
offset 0      header, 136 bytes (§2)
offset 136    u16 L, then L bytes: reference name (§2.2)
offset 138+L  meta section: meta_bytes bytes, one zstd frame (§4)
...           block-hash section: hash_bytes bytes (§12.2)
...           payload: payload_bytes bytes = the rANS streams of all blocks, block 0 first, back to back (§6, §9)
```

`payload_start = 138 + L + meta_bytes + hash_bytes` (exact, §0). File size MUST equal `payload_start + payload_bytes`.
Nothing precedes the header and nothing follows the payload.

## 2. Header

### 2.1 Fixed fields (136 bytes)

| offset | type | name | value / meaning |
|---:|---|---|---|
| 0 | 8 bytes | magic | `52 46 52 4C 33 56 31 00` = ASCII `RFRL3V1` + one zero byte |
| 8 | u32 | version | 1 |
| 12 | u32 | Q | block size in bases: 1024, 2048, 4096 or 16384 |
| 16 | u32 | flags | bit 0 = block-hash section present; bits 1..31 MUST be 0 |
| 20 | u32 | reserved | MUST be 0 (a reader refuses otherwise, §5 step 6) |
| 24 | 32 bytes | ref_sha256 | SHA-256 of the decoded reference base stream (§3.2) |
| 56 | u64 | ref_bases | number of bases of the decoded reference |
| 64 | u64 | n | bases of the assembly: all records concatenated (§3.3) |
| 72 | u64 | nblocks | ceil(n / Q) |
| 80 | u64 | fasta_xxh3 | XXH3 of the complete source FASTA file bytes (headers, line ends, everything) |
| 88 | u64 | bases_xxh3 | XXH3 of the assembly base stream with case kept (§3.3); see §12.4 |
| 96 | u64 | meta_bytes | size of the meta section (the zstd frame) in bytes |
| 104 | u64 | meta_raw | size of the meta after decompression |
| 112 | u64 | hash_bytes | 8 × nblocks if flags bit 0, else 0 |
| 120 | u64 | payload_bytes | total size of all block streams |
| 128 | u64 | header_xxh3 | XXH3 of bytes `[0, payload_start)` of the file computed with bytes 128..135 set to 0 |

`header_xxh3` covers the fixed header, the reference name, the meta section and the block-hash section. It does
**not** cover the payload; payload integrity rests on the rANS consistency checks (§15), the block XXH3 values (§12.2)
and `fasta_xxh3` (§12.3).

### 2.2 Reference name

`u16 L` at offset 136, then L raw bytes (no terminator, no encoding implied; the v1 encoder writes the reference file
name without directory, truncated to 65535 bytes). Informational only: binding to the reference is by `ref_sha256` and
`ref_bases`. A reader MUST NOT refuse because of the name.

## 3. FASTA model

### 3.1 Accepted FASTA layout (applies to the reference and to the assembly source)

A FASTA file is a sequence of records. Parsing is byte-exact:

1. The file MUST start with `>` (an empty file has zero records). Each record starts with a header line: `>` followed
   by the header bytes up to (not including) the next LF (0x0A). The header bytes are kept verbatim (spaces, tabs, CR
   if any).
2. Then zero or more sequence lines until the next line starting with `>` or the end of the file. Every line,
   including the last line of the file, MUST end with LF. A sequence line MUST NOT be empty.
3. Line width `lw` of a record = length of its first sequence line. Every sequence line MUST have length `lw` except
   the last line of the record, which MAY be shorter (≥ 1). After a shorter line no further sequence line may follow
   in that record. A record with no sequence lines has length 0 and `lw` = 0.
4. Base bytes are all bytes of the sequence lines except the LF; nothing else is removed (a CR before LF would be a
   base byte; IUPAC codes, `N`, `*`, `-` are base bytes like any other).

Files outside this layout cannot be encoded in v1 (the encoder refuses them).

**Reader side (the reference).** A reader MUST parse the reference FASTA by these rules and MUST refuse a reference
that violates them, before reading the archive (§5 step 0), with one of these reasons:

| violation | reason |
|---|---|
| a non-empty file whose first byte is not `>`, rule 1 (e.g. a file starting with a blank line) | `no header` |
| a sequence line not terminated by LF at the end of the file, rule 2 | `no final line end` |
| an empty sequence line; a line longer than `lw`; a sequence line after a shorter one, rules 2–3 | `irregular line layout` |

One tolerance: a last header line not terminated by LF at the end of the file (a final record of length 0) is accepted
by the v1 reader; it contributes no base to R, so R and `ref_sha256` are the same whether a reader accepts or refuses
it, and a reader MAY do either (reason `no final line end` if it refuses). A reference that cannot be read at all is
refused at step 0 with a reason of the reader's choice (the v1 reader prints the operating-system error).

### 3.2 Decoded reference

Parse the reference FASTA (§3.1); concatenate the base bytes of all records in file order, no separators; map every
byte in `a`..`z` (0x61..0x7A) to upper case by subtracting 0x20; all other bytes unchanged. The result `R`
(length `ref_bases`) is the **decoded reference**; `ref_sha256` = SHA-256(R). Contig boundaries of the reference play
no role: copy positions (§10) are offsets into `R`.

### 3.3 Assembly base stream, upper-case stream and case

`B` = base bytes of all assembly records concatenated in file order (case kept), length n. `U` = B with `a`..`z`
upper-cased as in §3.2. Blocks (§9) encode `U` only; the payload never encodes case. Case is restored by the
lower-case runs (§4.3): exactly the positions holding a byte in `a`..`z` in B are covered by runs, and restoring is
`byte | 0x20` at those positions (for a letter this gives its lower case).

### 3.4 Blocks

`U` is cut into `nblocks = ceil(n / Q)` blocks; block b covers `U[b·Q, b·Q + blen_b)` with
`blen_b = min(Q, n − b·Q)`. Only the last block can be shorter. If n = 0 there are no blocks.

## 4. Meta

The meta section is exactly one zstd frame of `meta_bytes` bytes whose frame header carries the content size, equal to
`meta_raw`; no dictionary. (The v1 encoder writes zstd level 19, single frame, content size present, no checksum.)
Decompressed, the meta is the concatenation of §4.1–§4.4 with **no trailing bytes**: the parser MUST end exactly at
`meta_raw`.

The frame requirements are checked at open, in this order (§5):

- step 12 `meta frame`: `meta_raw` ≤ 2^32 and the Frame_Content_Size of the frame header at the start of the section
  (RFC 8878 §3.1.1.1) is present and equals `meta_raw`. A frame header that cannot be parsed, or one without a content
  size, fails this step. A skippable frame (magic 0x184D2A50..0x184D2A5F) at the start counts as content size 0; since a
  valid meta is never empty, it fails this step unless `meta_raw` = 0, and then step 14 (`contig table`).
- step 12a `meta frame count`: the compressed size of the first frame — frame header, every block up to and including
  the block with Last_Block = 1, and the 4-byte content checksum if the header's Content_Checksum_flag is set — equals
  `meta_bytes` exactly. Any byte after the first frame (a second zstd frame, also an empty one; a skippable frame; any
  other bytes) fails this step, and so does a first frame that does not end inside the section (truncated).
- step 13 `meta decompress`: decompressing the frame yields exactly `meta_raw` bytes. This step also fails when the frame
  header carries a nonzero Dictionary_ID (no dictionary is ever supplied, so the frame cannot be decoded), when a block
  is corrupt, and when a content checksum is present and does not match. A content checksum is allowed (the v1 encoder
  does not write one) and, if present, MUST be verified.

### 4.1 Contig table

```
u32 nrec
repeat nrec:
    u32 hlen
    hlen bytes  header (the FASTA header line without '>' and without LF, verbatim)
    u64 len     bases of the record
    u32 lw      line width (§3.1); 0 iff the record has no sequence lines
```

Record r starts at base offset `boff_r = Σ len of records before r` in B/U. Σ len MUST equal n. A record with
len > 0 MUST have lw > 0. Records are not aligned to blocks: a block can span several records and a record several
blocks. Record names for fetch: §14.

### 4.2 Lower-case runs

```
u64 nruns
repeat nruns:
    LEB128 gap     bases from the end of the previous run (from 0 for the first run) to the start of this run
    LEB128 length  bases in the run
```

Run k covers `[s_k, s_k + length_k)` with `s_k = e_{k−1} + gap_k`, `e_{k−1}` = end of the previous run (0 before the
first). Runs are therefore sorted and do not overlap. Every run MUST end at or before n. A run MAY cross a record
boundary (the encoder scans the concatenated stream; a lower-case record end followed by a lower-case record start
forms one run). The v1 encoder never writes a run of length 0 and never writes gap = 0 except for a run starting at
position 0 (runs are maximal); a reader MUST accept length-0 runs (they change nothing).

### 4.3 Model tables

For each context c = 0..60 in order (§8), for each symbol s = 0..A_c − 1 in order, one LEB128 frequency f[c][s].
Alphabet sizes A_c are in §8 (Σ A_c = 1827 values in total). Every f MUST be ≤ 4096 and for each context the sum MUST be
exactly 4096 or exactly 0 (an all-zero context is never used by a valid stream; a decoder reaching it fails, §6.3).

### 4.4 Block table

```
repeat nblocks (count from the header):
    LEB128 slen_b          bytes of block b's rANS stream
    LEB128 v_b             block start diagonal, coded against a prediction
```

Interleaved pairs, block 0 first. Payload offset of block b = Σ slen of blocks before b; Σ slen MUST equal
payload_bytes.

**Block start diagonal** (named "start state" in older notes; it is unrelated to the rANS state of §6): a pair
`(c_b, dir_b)` with `c_b` a 64-bit diagonal value (§10.1) and `dir_b` ∈ {0 forward, 1 reverse complement}. Decode:

```
dir_b = v_b & 1
q     = v_b >> 1
delta = (int64)(q >> 1) XOR −(int64)(q & 1)          // zig-zag decode, §7.2
pred  = 0                               if b = 0                      (block 0 of the archive only)
        c_{b−1} − Q   (mod 2^64)        if b > 0 and dir_{b−1} = 1
        c_{b−1} + Q   (mod 2^64)        if b > 0 and dir_{b−1} = 0
c_b   = pred + delta  (mod 2^64)
```

The prediction uses the **previous block's** decoded `(c, dir)`; contig boundaries play no role. `(c_b, dir_b)` is
the only entry of block b's diagonal cache when its decoding starts (§10.2). It is a prediction aid only: any value is
legal; a wrong value makes the block's stream decode to different symbols and fail the checks (§15).

## 5. Open checks (normative order)

A reader MUST perform these checks before decoding any block, in this order, and refuse at the first failure with the
reason in brackets.

**Reason strings are normative** (1.0.1). On a refusal a conforming reader reports the stage — `open` for §5,
`decode` for a full decode (§13, §15), `fetch` for a region fetch (§14) — and the reason string exactly as written
here (byte for byte, case and punctuation included). It MAY append a detail after the reason, separated by one space and
enclosed in parentheses, e.g. `block XXH3 (block 64)`; a reason compares equal if the reported text equals the reason or
starts with the reason followed by ` (`. The surrounding message is informative; the v1 reader prints
`refused: <reason>` for an open refusal and `decode failed (<reason>)` for a failed full decode. §20 lists every reason.

0. the reference FASTA parses by §3.1 [no header / no final line end / irregular line layout, §3.1 "Reader side"] —
   done when the reference is loaded, before any byte of the archive is examined
1. file size ≥ 138 [short file]
2. magic [magic]
3. version = 1 [version]
4. Q ∈ {1024, 2048, 4096, 16384} [block size]
5. flags & ~1 = 0 [unknown flags]
6. reserved = 0 [reserved]
7. section sizes: with L = u16 at 136 and `payload_start = 138 + L + meta_bytes + hash_bytes`, each of meta_bytes,
   hash_bytes, payload_bytes, payload_start ≤ file size, and payload_start + payload_bytes = file size [section sizes]
8. nblocks = ceil(n / Q) (and nblocks > 0 if n > 0) [block count]
9. hash_bytes = 8 × nblocks if flags bit 0 else 0 [hash section size]
10. header_xxh3 (§2.1) [header XXH3]
11. ref_sha256 = SHA-256 of the loaded decoded reference and ref_bases = its length [reference SHA-256 / size differs] —
    the "wrong reference" refusal
12. meta_raw ≤ 2^32 and the zstd frame header's content size = meta_raw [meta frame] (§4)
12a. the meta section is exactly one zstd frame: the first frame's compressed size = meta_bytes [meta frame count] (§4).
    Numbered 12a so that steps 13–17 keep their numbers.
13. decompressing the meta_bytes bytes yields exactly meta_raw bytes [meta decompress] (§4: also a nonzero
    Dictionary_ID, a corrupt block, a wrong content checksum)
14. contig table (§4.1), two reasons:
    - nrec > meta_raw [records] — tested on the u32 nrec alone, before any record is parsed;
    - otherwise [contig table] if a record runs past the end of the meta (hlen, header bytes, len or lw), or a record
      has len > 0 and lw = 0, or Σ len ≠ n. `records` and `contig table` are two distinct reason strings.
15. nruns ≤ n; every run's two LEB128 values parse (§0) and every run ends ≤ n [case runs]
16. every frequency parses (§0) and is ≤ 4096; every context sums to 4096 or 0 [model tables]
17. block table parses (§0), the meta is consumed exactly (no trailing byte), Σ slen = payload_bytes [block table]

All sums and comparisons above are exact (§0); "parses" includes the LEB128 rules of §0 (past the end of the meta, or
more than 10 bytes). Because step 8 precedes step 10, a damaged n or nblocks field is reported as "block count", not
"header XXH3". After step 17 the archive is open; per-block failures are reported only when a block is decoded (§15).

## 6. Entropy coder (rANS, byte-wise, 24-bit state)

### 6.1 Parameters

| name | value |
|---|---|
| probability precision | 12 bits: M = 4096 (every used context's frequencies sum to M) |
| state lower bound | L_LO = 2^16 = 65536 |
| state range | x ∈ [2^16, 2^24) between symbols |
| I/O unit | 1 byte |
| initial bytes | 3 (the encoder's final state, little-endian) |
| final state | exactly L_LO = 65536 |

One independent stream per block, `slen_b` bytes. Streams are read **forward** (from the block's first payload byte
towards its end). The encoder encodes the symbols in reverse order and writes bytes backwards, so no stream is stored
reversed: a decoder simply reads forward.

### 6.2 Per-context tables

For context c with frequencies f[c][0..A_c−1]: `cum[c][s] = Σ_{t<s} f[c][t]`; slot table `sym[c][j] = s` for
`cum[c][s] ≤ j < cum[c][s] + f[c][s]`, j = 0..4095. Symbol order is the alphabet index order of §8.
For an all-zero context, `sym[c][j]` = 0 and `f[c][0]` = 0 for every j.

### 6.3 Decoder

```
init(stream bytes p[0..slen−1]):
    if slen < 3: FAIL
    x   = p[0] | p[1] << 8 | p[2] << 16          // 24-bit initial state, little-endian
    pos = 3

renorm():
    while x < 65536:
        if pos = slen: FAIL                      // stream exhausted
        x = (x << 8) | p[pos]; pos = pos + 1

decode_symbol(c):
    slot = x & 4095
    s    = sym[c][slot]
    f    = f[c][s];  if f = 0: FAIL              // all-zero context
    x    = f * (x >> 12) + slot − cum[c][s]
    renorm()
    return s

read_bits(k):                                    // k ≤ 64; chunks of ≤ 16 bits, least significant chunk first
    v = 0; sh = 0
    while k > 0:
        t = min(16, k)
        b = x & (2^t − 1); x = x >> t
        renorm()
        v = v | (b << sh); sh = sh + t; k = k − t
    return v

finish():
    if x ≠ 65536 or pos ≠ slen: FAIL             // the stream is consumed exactly with the final state
```

x fits in 32 bits throughout (f·(x >> 12) ≤ 4096·4095 + slot < 2^24). Any FAIL makes the block invalid (§15).

### 6.4 Encoder (for reference; exact inverse)

Symbols are encoded last-first starting from x = 65536. A coded symbol s of context c: let
`x_max = ((65536 >> 12) << 8) · f = 4096 · f`; while x ≥ x_max output the byte `x & 0xFF` and x >>= 8 (bytes are
prepended); then `x = (x / f) << 12 + (x mod f) + cum[c][s]`. A raw chunk of t bits with value b:
`x_max = (65536 >> t) << 8`; while x ≥ x_max emit a byte as above; then `x = (x << t) + b`. A raw field of k > 16 bits
is split into chunks of 16, 16, ..., remainder (least significant first in the decoder) and the chunks are encoded in
reverse. Finally the 3 bytes `x & 0xFF, (x >> 8) & 0xFF, (x >> 16) & 0xFF` are prepended.

## 7. Integer coding

### 7.1 Bucketed values (alphabet of 104 symbols)

A value v ∈ [0, 2^26) is coded as a bucket symbol s (with a context, §8) followed by `nbits(s)` raw bits (§6.3
read_bits):

```
s < 16:  value = s, nbits = 0
s ≥ 16:  e = (s − 16) / 4 + 4 (integer division),  m = (s − 16) mod 4
         nbits = e − 2
         value = 2^e + m · 2^(e−2) + extra,  extra = read_bits(nbits)
```

Encoder side: v < 16 → s = v; else e = floor(log2 v) (≥ 4), s = 16 + 4(e − 4) + ((v >> (e − 2)) & 3),
extra = v mod 2^(e−2). Symbol 103 gives e = 25 (values < 2^26). Table: s = 16..19 → 16..31 (2 extra bits),
20..23 → 32..63 (3 bits), …, 100..103 → 2^25..2^26 − 1 (23 bits).

`read_value(c)` = decode_symbol(c), then the extra bits.

### 7.2 Zig-zag

`zz(d) = (d << 1) XOR (d >> 63)` (arithmetic shift) maps int64 to uint64: 0, −1, 1, −2, 2 → 0, 1, 2, 3, 4.
Inverse: `unzz(z) = (int64)(z >> 1) XOR −(int64)(z & 1)`.

## 8. Contexts (61) and alphabets

| context ids | count | alphabet A_c | field | context index within the group |
|---|---:|---:|---|---|
| 0..3 | 4 | 104 | LL: literal count of an event (bucketed) | kclass(prevk) |
| 4..13 | 10 | 6 | literal, short run (LL ≤ 8) | 2 · refbase + (j = 0 ? 1 : 0) |
| 14..30 | 17 | 6 | literal, long run (LL > 8), order-2 | o2 (see below) |
| 31..46 | 16 | 6 | KIND | 4 · llc(LL) + kclass(prevk) |
| 47..48 | 2 | 104 | DELTA magnitude zz(d) (bucketed) | LL = 0 ? 0 : 1 |
| 49 | 1 | 3 | REP: which older cached diagonal (1 + symbol) | – |
| 50 | 1 | 104 | REP delta zz(d) (bucketed) | – |
| 51 | 1 | 2 | ABS strand (0 forward, 1 reverse complement) | – |
| 52 | 1 | 104 | SELF distance (bucketed) | – |
| 53..58 | 6 | 104 | copy length − 12 (bucketed) | kind (0..5) |
| 59 | 1 | 4 | FLIP: which cached diagonal (symbol 0..3) | – |
| 60 | 1 | 104 | FLIP delta zz(d) (bucketed) | – |

Alphabet list in context order, A_0..A_60:
`104,104,104,104, 6×10, 6×17, 6×16, 104,104, 3, 104, 2, 104, 104×6, 4, 104` (Σ = 1827).

Helper functions:

- `kclass(k)`: k = none (before the first copy of the block) → 0; CONT → 1; DELTA, REP, FLIP → 2; ABS, SELF → 3.
- `llc(LL)`: 0 → 0; 1 → 1; 2..8 → 2; ≥ 9 → 3.
- Kind symbols: 0 CONT, 1 DELTA, 2 REP, 3 ABS, 4 SELF, 5 FLIP.
- Literal symbols: 0 `A`, 1 `C`, 2 `G`, 3 `T`, 4 `N`, 5 escape (the literal byte is the next `read_bits(8)`, any value
  0..255; this is how bytes other than ACGTN are coded).
- `refbase(o)`: with the current diagonal g = cache[0] (§10.2) and block offset o: `q = g.c − o` if g.dir = 1 else
  `g.c + o` (int64). If q < 0 or q ≥ ref_bases → 4. Else let r = R[q]; if g.dir = 1 then r = comp(r) (§11). r ∈ {A, C, G, T}
  → 0, 1, 2, 3; any other byte (N included) → 4. Values 0..4 → 10 contexts with the run-start flag.
- `o2` for literal j of a long run: keep p1, p2, both set to 16 at the start of each literal run. Context index:
  p1 = 16 → 16; else p2 = 16 → p1; else 4 · p2 + p1. After each literal with symbol s: p2 = p1; p1 = (s < 4 ? s : 0)
  (N and escape count as A). So index 16 = first literal of the run, 0..3 = second literal, 0..15 = later literals.
- `prevk` = kind of the last copy decoded in this block, "none" at block start; literal runs do not change it.

## 9. Block grammar

A block is a sequence of **events**; each event is a literal run (possibly empty) followed by a copy, except that the
block ends as soon as `blen` bases are produced (so the last event may be a literal run without a copy, and a block may
end right after a copy). With o = bases produced so far:

```
o = 0; prevk = none; cache = [(c_b, dir_b)]                       // §4.4, §10.2
while o < blen:
    LL = read_value(LL context kclass(prevk))                      // always present, may be 0
    if LL > blen − o: FAIL
    literals j = 0..LL−1 at offsets o..o+LL−1 (§8: context 4..13 if LL ≤ 8, else 14..30)
    o = o + LL
    if o = blen: break
    kind = decode_symbol(31 + 4·llc(LL) + kclass(prevk))
    parameters by kind (§10.3)
    len = read_value(53 + kind) + 12                               // minimum copy length 12, all kinds
    if len > blen − o: FAIL
    resolve and check the copy (§10.3), update the cache (§10.2)
    o = o + len; prevk = kind
finish()                                                           // §6.3
```

Values above an alphabet are never escaped: every count, distance, delta and length is a bucketed value (§7.1) of
< 2^26, the absolute position is 32 raw bits. Values beyond those ranges cannot occur in v1.

## 10. Copies and the diagonal cache

### 10.1 Diagonals

A reference copy has a strand `dir`, a reference start p (lowest reference position read) and length len, and lands at
block offset o. Its diagonal value:

```
forward (dir = 0):          c = p − o                // the copy continues at reference p' = c + o' for offset o'
reverse complement (dir=1): c = p + len − 1 + o      // reference position of offset o' read backwards: c − o'
```

c is stored as the 64-bit two's-complement pattern of the int64 result (it may be negative).
Expected start of a copy of length len at offset o on diagonal g: `exp(g, o, len) = g.c + o` if g.dir = 0, else
`g.c − o − len + 1`. Locus of g at offset o: `locus(g, o) = g.c + o` if g.dir = 0, else `g.c − o`.

### 10.2 Cache

At most 4 diagonals, most recent first; `nc` = entries in use. At block start: `cache = [(c_b, dir_b)]`, nc = 1
(nothing carries over from other blocks except through §4.4). After every **reference** copy (kinds CONT, DELTA, REP,
ABS, FLIP — not SELF) push g' = its diagonal (§10.1): if an entry with equal (c, dir) exists at index j, remove it;
otherwise, if nc < 4 then nc = nc + 1, else drop the last entry; then insert g' at index 0. cache[0] is the "current
diagonal" used by `refbase` (§8) and by CONT/DELTA.

### 10.3 Kinds

| kind | parameters (in stream order) | strand and start p |
|---|---|---|
| 0 CONT | none | g = cache[0]; dir = g.dir; p = exp(g, o, len) |
| 1 DELTA | d = unzz(read_value(47 + (LL = 0 ? 0 : 1))) | g = cache[0]; dir = g.dir; p = exp(g, o, len) + d |
| 2 REP | i = 1 + decode_symbol(49); d = unzz(read_value(50)) | FAIL if i ≥ nc; g = cache[i]; dir = g.dir; p = exp(g, o, len) + d |
| 3 ABS | dir = decode_symbol(51); p = read_bits(32) | as read |
| 4 SELF | dist = read_value(52) | in-block copy from offset o − dist; FAIL if dist = 0 or dist > o |
| 5 FLIP | i = decode_symbol(59); d = unzz(read_value(60)) | FAIL if i ≥ nc; g = cache[i]; dir = 1 − g.dir; p = locus(g, o) + d |

Order inside the event: kind, parameters (as listed), then the length (§9). For CONT/DELTA/REP the start depends on
len, so p is computed after len is read. For REP and FLIP the index check happens after their delta is read.

Checks for every reference copy (all kinds except SELF): the int64 start p MUST be ≥ 0 and `p + len ≤ ref_bases`
(i.e. p ≤ ref_bases and len ≤ ref_bases − p). Reading `N` or any other byte of R is legal. For a reverse-complement
copy the same interval `[p, p + len)` is checked (it is read backwards, §11). A SELF copy MAY overlap its own output
(dist < len): it is executed byte by byte forward, so it repeats the last dist bases.

## 11. Block execution

Block output `out[0..blen)` (upper-case bytes) is produced in event order:

- literal j of a run at offset o + j: the byte given by its symbol (§8).
- forward copy: `out[o + j] = R[p + j]`, j = 0..len−1.
- reverse-complement copy: `out[o + j] = comp(R[p + len − 1 − j])`.
- self copy: `out[o + j] = out[o − dist + j]`, sequentially in increasing j.

`comp`: A↔T, C↔G (upper case only); every other byte (N, IUPAC codes, lower case cannot occur in R) maps to itself.

Operation count (1.0.1). Counting one operation per non-empty literal run and one per copy, a block of blen bases has
at most `2 · floor(blen / 13) + (blen mod 13 > 0 ? 1 : 0)` operations, for any stream that passes §9 (a copy is ≥ 12
bases, a non-empty literal run ≥ 1 base): 2 521 for blen = 16 384. The v1 reader's work array holds 4096 operations,
so its limit is never reached and is not a check: it is not in §15, has no reason string, and a reader MUST NOT refuse
a block for its number of operations. (Were a reader's own capacity exceeded, the block would count as invalid with
reason `block`, §15.) Likewise the literal bytes of a block never exceed blen ≤ Q.

## 12. Hashes

### 12.1 Header XXH3 — §2.1. Checked on open (§5 step 10).

### 12.2 Block XXH3 (flags bit 0)

Block-hash section: for b = 0..nblocks−1, u64 = XXH3 of block b's decoded output `out[0..blen_b)` (upper case, before
lower-case runs). Located right after the meta section; covered by the header XXH3.

### 12.3 Source FASTA XXH3

`fasta_xxh3` = XXH3 of the full source FASTA file. A full decode (§13) MUST compare it with the rebuilt file.

### 12.4 Base-stream XXH3

`bases_xxh3` = XXH3 of B (case kept, no headers, no line ends). Informational in v1: the v1 reader does not check it.
A reader MAY verify it after a full decode and refuse on mismatch (a valid archive always matches); it adds nothing to
`fasta_xxh3` for a full decode.

If a reader verifies it (1.0.1): only in a full decode, after every check of §13 has passed (so after `FASTA XXH3`);
on mismatch it refuses at stage `decode` with the reason `bases XXH3` and writes nothing. A fetch MUST NOT apply it.
This reason string is defined here for readers that choose the check; the v1 reader never emits it, the field is
covered by `header_xxh3` (a mismatch requires a recomputed header XXH3), and no conformance test depends on it: a
reader that does not check `bases_xxh3` is fully conforming.

## 13. Full decode

1. Open (§5).
2. Decode every block (§9–§11) into U; verify each block's XXH3 if present (§12.2).
3. For every lower-case run `[s, s + length)`: `U[x] = U[x] | 0x20` → B.
4. Rebuild the FASTA: for each record in table order: `>`, header bytes, LF; then the record's bases in lines of `lw`
   bases (last line shorter if needed), each followed by LF. A record with len = 0 is the header line only. The file
   ends with the LF of its last line.
5. XXH3 of the rebuilt bytes MUST equal fasta_xxh3.
6. Output only after all checks pass (no partial FASTA on any failure).

Refusal reasons of a full decode (stage `decode`, §15): `block` (a block fails a check of §15 other than its XXH3),
`block XXH3` (a block decodes but its stored XXH3 differs), `FASTA XXH3` (every block passed, step 5 fails). Every
block check comes before `FASTA XXH3`. Within one block, `block` takes precedence over `block XXH3` (the XXH3 is
computed only over a successfully decoded block). If several blocks are invalid, the reported reason MAY be that of any
of them (the v1 reader decodes blocks in parallel and reports the first failure it observes).

## 14. Region fetch

Name of a record = its header bytes up to (not including) the first space (0x20) or tab (0x09), or the whole header.
A fetch resolves a name to the **first** record in table order with that name (later duplicates are unreachable by
name). Canonical request: `(name, start0, end0)`, zero-based half-open, valid iff `0 ≤ start0 < end0 ≤ len`
(equivalently `(name, start0, length)` with length = end0 − start0 ≥ 1). The 1-based inclusive form
`name:start1-end1` maps to start0 = start1 − 1, end0 = end1.

Answer: bases `B[boff + start0, boff + end0)`, letter case as in the source, no line breaks. Procedure: decode the
blocks `floor((boff + start0)/Q) .. floor((boff + end0 − 1)/Q)`, verify each decoded block's XXH3 if the archive has
them, take the bytes, apply the lower-case runs that intersect the interval. A fetch MUST perform all open checks (§5)
and all decode checks of the blocks it touches (§15). `fasta_xxh3` cannot be applied to a fetch. Consequence: in an
archive without block hashes, a fetch is protected only by the rANS consistency checks of the touched blocks; two
payload blocks of equal length swapped such that both still decode are not detectable on fetch without block hashes
(they are detected by a full decode through fasta_xxh3).

Fetch refusals (1.0.1, stage `fetch`). After the open checks (§5, stage `open`), each request is checked on its own:

| condition | reason | v1 reader message (informative) |
|---|---|---|
| no record has this name | `no contig` | `no contig <name>` |
| not `0 ≤ start0 < end0 ≤ len` — start beyond the record, end beyond the record, zero or negative length; this includes any request on a record of length 0 | `bad range` | `bad range <request>` |
| a touched block fails a check of §15 or its block XXH3 differs | `block` | `block <b> failed` |

A refused request returns no bases. The checks are per request: after `no contig` or `bad range` the v1 reader goes
on with the next request of the same call and ends with a failure status; after `block` it stops the call (later
requests are not served). A failed block XXH3 on fetch has the same reason `block` as any other block failure (the v1
reader does not distinguish the two on fetch).

## 15. Decode-time checks (a conforming reader performs all of them; there is no "checks off" mode in conformance)

A block is invalid, and the decode or fetch that needs it fails with no output, if any of these occurs:
stream shorter than 3 bytes; stream exhausted during renormalisation; a symbol with frequency 0; LL > blen − o; a kind
symbol ≥ 6 (cannot occur with a 6-symbol alphabet but MUST be rejected); REP/FLIP index ≥ nc; a negative reference start;
a reference copy outside R; SELF dist = 0 or > o; len > blen − o; at the end x ≠ 65536 or bytes left unread; the block
XXH3 differs (when present). A full decode additionally fails if the FASTA XXH3 differs.
Refusal means: report an error and write nothing (no partial FASTA, no region bytes).

Reasons (1.0.1, normative, §5 for the matching rule):

| stage | condition | reason |
|---|---|---|
| decode | any condition of the list above except the block XXH3 | `block` |
| decode | the block decodes, its stored XXH3 differs | `block XXH3` |
| decode | all blocks pass, the rebuilt FASTA's XXH3 differs from `fasta_xxh3` (§13 step 5) | `FASTA XXH3` |
| fetch | a touched block fails (either of the first two rows) | `block` |

The list above is complete: the operation count (§11) is not a check, and the `bases_xxh3` comparison (§12.4) is
optional and comes after all of them. Precedence and multiple failures: §13.

## 16. Constants

| constant | value |
|---|---|
| magic | `RFRL3V1\0` |
| version | 1 |
| header size | 136 (+ 2 + L before the meta) |
| Q | 1024, 2048, 4096, 16384 |
| flag bit 0 | block-hash section present |
| contexts | 61 (§8) |
| bucket alphabet | 104 symbols, values < 2^26 |
| probability precision | 12 bits, M = 4096 |
| rANS state | [2^16, 2^24), init 3 bytes LE, final 2^16 |
| raw-bit chunk | ≤ 16 bits, least significant chunk first |
| ABS position | 32 raw bits |
| minimum copy length | 12 |
| diagonal cache | 4 entries, move-to-front |
| delta range used by the encoder | |d| < 2^24 for DELTA/REP/FLIP (beyond: ABS); decoder: any bucketed value |
| literal symbols | A C G T N escape(8 raw bits) |
| short literal run | LL ≤ 8 |
| XXH3 | XXH3_64bits, seed 0, stored as u64 LE |

## 17. Block decoder pseudocode (complete)

```
decode_block(stream, blen, (c0, dir0), R, tables) -> out[0..blen)
    init(stream)
    cache = [(c0, dir0)]; nc = 1; prevk = NONE; o = 0
    while o < blen:
        LL = read_value(0 + kclass(prevk))
        if LL > blen - o: FAIL
        p1 = p2 = 16
        for j in 0..LL-1:
            if LL <= 8: ctx = 4 + 2*refbase(cache[0], o + j) + (j == 0 ? 1 : 0)
            else:       ctx = 14 + (p1 == 16 ? 16 : p2 == 16 ? p1 : 4*p2 + p1)
            s = decode_symbol(ctx)
            out[o + j] = s < 5 ? "ACGTN"[s] : read_bits(8)
            p2 = p1; p1 = s < 4 ? s : 0
        o += LL
        if o == blen: break
        kind = decode_symbol(31 + 4*llc(LL) + kclass(prevk))
        d = 0; dist = 0
        if kind == DELTA: d = unzz(read_value(LL == 0 ? 47 : 48))
        elif kind == REP: i = 1 + decode_symbol(49); d = unzz(read_value(50)); if i >= nc: FAIL
        elif kind == ABS: dir = decode_symbol(51); p = read_bits(32)
        elif kind == SELF: dist = read_value(52)
        elif kind == FLIP: i = decode_symbol(59); d = unzz(read_value(60)); if i >= nc: FAIL
        elif kind != CONT: FAIL
        len = read_value(53 + kind) + 12
        if len > blen - o: FAIL
        if kind == SELF:
            if dist == 0 or dist > o: FAIL
            for j in 0..len-1: out[o + j] = out[o - dist + j]
        else:
            if kind == FLIP: g = cache[i]; dir = 1 - g.dir; p = locus(g, o) + d
            elif kind != ABS: g = cache[kind == REP ? i : 0]; dir = g.dir; p = exp(g, o, len) + d
            if p < 0 or p > |R| or len > |R| - p: FAIL
            for j in 0..len-1: out[o + j] = dir == 0 ? R[p + j] : comp(R[p + len - 1 - j])
            push(cache, diagonal(dir, p, o, len))
        o += len; prevk = kind
    finish()
```

## 18. Encoder-side facts (non-normative; they explain the bytes, a reader does not rely on them)

- Static models: per archive, symbol counts over all blocks; frequencies normalised to 4096 with every seen symbol ≥ 1
  (`f = max(1, floor(count · 4096 / total))`, then the most frequent symbol is incremented, or the largest frequency > 1
  decremented, until the sum is 4096); unused contexts all zero.
- Block start diagonals: the diagonal the previous block ended with, advanced by Q in its direction (two passes).
- Encoder bytes depend on floating-point contraction of the compiler; decoding does not.
- The source FASTA must follow §3.1; the encoder refuses other layouts.

## 19. Versioning

A reader accepts version 1 only. Any change of layout, contexts, alphabets, coder or check order is a new version;
v1 archives stay decodable by a v1 reader.

## 20. Refusal reasons (summary, normative strings)

| stage | step / section | reason |
|---|---|---|
| open | §5 step 0, §3.1 | `no header` · `no final line end` · `irregular line layout` |
| open | §5 steps 1–11 | `short file` · `magic` · `version` · `block size` · `unknown flags` · `reserved` · `section sizes` · `block count` · `hash section size` · `header XXH3` · `reference SHA-256 / size differs` |
| open | §5 steps 12, 12a, 13 | `meta frame` · `meta frame count` · `meta decompress` |
| open | §5 steps 14–17 | `records` · `contig table` · `case runs` · `model tables` · `block table` |
| decode | §13, §15 | `block` · `block XXH3` · `FASTA XXH3` · (optional check, §12.4) `bases XXH3` |
| fetch | §14 | `no contig` · `bad range` · `block` |

Each string is exact (byte for byte); a detail MAY follow as ` (<detail>)` (§5). On every refusal nothing is written.

## 21. Notes on the v1 reader (informative)

The reason strings of §20 are those printed by the v1 reader, with one addition: `meta frame count` (step 12a) is the
reason of the v1 reader revision that performs that check; the first v1 reader did not perform step 12a. Places where a
v1 reader is more lenient than this document — all concern files that no v1 encoder writes; on every valid archive the
results are identical:

- Step 12a (first reader): it decompresses all frames of the section into `meta_raw` bytes, so a meta followed by an
  empty zstd frame or a skippable frame is accepted; other trailing bytes and a truncated frame are refused there as
  `meta decompress`. This document requires `meta frame count` for all of these.
- All-zero context (§6.3): the v1 reader marks the stream bad and fails the block at the next count or length check or
  at `finish`; a stream that reaches an all-zero context only inside the final literal run of a block and still ends
  with x = 65536 and every byte read would be accepted by it. This document fails the block at once (`block` either way).
- Exact arithmetic (§0): the v1 reader computes the open checks in u64. For steps 7 and 8 this is equivalent to exact
  arithmetic (each of meta_bytes, hash_bytes, payload_bytes is first checked ≤ file size; the extra clause "nblocks > 0
  if n > 0" of step 8 catches the only wrap of `ceil(n / Q)`). In steps 14 (Σ len), 15 (run end) and 17 (Σ slen) its
  sums can wrap past 2^64 for field values no encoder writes; such archives are invalid and this document refuses them
  with the reason of the step.

## Changelog

### 1.0.1 (editorial; bytes unchanged) — 2026-10-08

No change to the archive bytes, the format, the encoder or the set of valid archives. Clarifications:

- §5 step 12a and §4: "exactly one zstd frame" is an explicit open step with the reason `meta frame count`; what fails
  step 12, 12a or 13 (skippable frame, trailing bytes, truncated frame, dictionary, checksum) is stated.
- §5, §13, §14, §15, §20: refusal reason strings are normative, with a matching rule (exact, optional ` (<detail>)`);
  decode-stage reasons `block`, `block XXH3`, `FASTA XXH3`, their precedence and the multiple-failure rule.
- §3.1, §5 step 0: a reader refuses a reference FASTA outside §3.1 before reading the archive (reasons `no header`,
  `no final line end`, `irregular line layout`); the final header line without LF tolerance.
- §5 step 14: `records` (nrec > meta_raw) and `contig table` are two distinct reasons.
- §0, §1, §5: size and count arithmetic is exact, not modulo 2^64.
- §4, §5 step 13: a nonzero Dictionary_ID fails `meta decompress`; a content checksum, if present, is verified.
- §14: invalid fetch requests (`no contig`, `bad range`) and fetch block failures (`block`).
- §11, §15: the operation bound (2 521 for Q = 16 384); the 4096-operation array of the v1 reader is not a check.
- §12.4: optional `bases_xxh3` check: when, stage `decode`, reason `bases XXH3`; not used by any conformance test.
- §20 (reason summary) and §21 (notes on the v1 reader) added; §0–§19 keep their numbers.
