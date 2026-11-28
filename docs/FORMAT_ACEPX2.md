# ACEPX2 archive format — normative specification, version 1 (2026-09-28)

Revision 2026-11-28 (ACEAPEX 2.6.7, SPEC-VAL-1): the refusal rules of readers collected in §8 and made one rule across the
reference readers. Nothing changes in what writers produce; no archive of a release is refused (§8).

This document is sufficient to write a decoder. Everything a reader needs is stated
here; nothing is taken from the reader's environment except for archives written before
the chunk field existed (§4.1, marked LEGACY). The reference implementations are
`c/aceapex_decode.c` (C99) and `src/aceapex_main.cpp` (C++); conformance
fixtures live in `verify/fixtures/` and are judged by `make test`. Where this text and
the code disagree, the fixtures decide and the text is fixed.

Conventions: all integers little-endian; `u32`/`u64` fixed width; offsets are byte
offsets from the start of the archive unless stated. "MUST" and "MUST NOT" are hard
requirements on readers; a reader that cannot satisfy one MUST fail the whole call
rather than return partial or guessed bytes (fail-closed).

## 1. Container

    [0]                    AetHeader, 68 bytes
    [68]                   BlockOffsets x num_blocks, 64 bytes each
    [68 + 64*num_blocks]   literal stream   (zlit_sz bytes)
    [+zlit_sz]             offset stream    (zoff_sz bytes)
    [+zoff_sz]             length stream    (zlen_sz bytes)
    [+zlen_sz]             command stream   (zcmd_sz bytes)

The archive MUST be at least 68 + 64*num_blocks + zlit_sz + zoff_sz + zlen_sz + zcmd_sz
bytes; trailing bytes after the command stream are not part of the format.

### 1.1 AetHeader (68 bytes, no padding)

| off | size | field | value |
|---|---|---|---|
| 0 | 8 | magic | ASCII `ACEPX2` then two zero bytes |
| 8 | u32 | version | 2. Readers MUST reject any other value. |
| 12 | u64 | orig_size | length of the original input |
| 20 | u32 | block_size | > 0; every block but the last is exactly this long; encoders write at most 64 MiB (see below) |
| 24 | u32 | num_blocks | ceil(orig_size / block_size); 0 only for the empty archive |
| 28 | 8 | xxhash | XXH3-64 of the original input, little-endian |
| 36 | u64 | zlit_sz | size of the literal stream as stored |
| 44 | u64 | zoff_sz | offset stream as stored |
| 52 | u64 | zlen_sz | length stream as stored |
| 60 | u64 | zcmd_sz | command stream as stored |

The header is 4-byte aligned in the file and the BlockOffsets table starts at offset 68,
so a reader MUST NOT cast the table to a struct of u64 on platforms that require
8-byte alignment; read fields with byte copies.

Invariants a reader MUST check before touching any stream: `num_blocks * block_size >=
orig_size` and `(num_blocks - 1) * block_size < orig_size` (the last block is not empty); the container size above
fits in the input, each stream size checked against the bytes left so the sum cannot wrap; every BlockOffsets slice
lies inside its decoded stream (§2), checked as offset and size.

Block size bound (2.6.4): encoders MUST NOT write `block_size` above 64 MiB (67 108 864; the reference encoder writes
256 KiB to 1 MiB), and a decoder MAY refuse an archive with a larger `block_size` (the reference decoders do, with
`ACEAPEX_ERR_DATA`). A block is decoded whole, so the bound limits the memory a single block can demand - the role of
zstd's `windowLogMax`.

### 1.2 Empty archive

An empty input is exactly one header: `num_blocks = 0`, `orig_size = 0`, all four
`z*_sz = 0`, `block_size != 0` (encoders write 65536), `xxhash` = XXH3-64 of zero bytes
(`2d06800538d394c2`). Readers accept `num_blocks = 0` only under these conditions, and with `version` 2 and the
`block_size` bound of §1.1 as for any archive (2.6.7). A reader MAY refuse empty archives altogether (the GPU library does:
it decodes nothing on a device).
A region read of length 0 returns 0 bytes; any other length is an error.
Fixture: `verify/fixtures/empty.aet`.

### 1.3 BlockOffsets (64 bytes per block)

    u64 lit_off, off_off, len_off, cmd_off;   // start of this block's slice in the DECODED stream
    u64 lit_sz,  off_sz,  len_sz,  cmd_sz;    // length of the slice

Offsets address the streams after entropy decoding (§3–4), not their stored form.
Block `b` reproduces original bytes `[b*block_size, min((b+1)*block_size, orig_size))`
from its four slices and from nothing else: no block reads another block's output.
This is the property that makes any block decodable alone, on a CPU or a GPU.
Slices follow each other (2.6.6): in each stream block 0's slice starts at 0 and block b's where block b-1's ends (`lit_off[b] = lit_off[b-1] + lit_sz[b-1]`, the same for off, len and cmd); a reader MUST reject any other table. A whole-archive
reader checks every entry; a region reader (§4) MUST check the entries of the blocks it decodes and of their two neighbours
and MAY check the whole table (2.6.7).

## 2. Block decoding (the match layer)

Inputs: the four slices `lit[0..lit_sz)`, `off[0..off_sz)`, `len[0..len_sz)`,
`cmd[0..cmd_sz)`, and the block's output length `dst_size`. State: output position
`out = 0`, read cursors `lp = op = np = cp = 0`, repeat-distance table
`rep[4] = {1, 2, 4, 8}`.

Read command bytes `c = cmd[cp++]` while `out < dst_size` and `cp < cmd_sz`:

| c | meaning |
|---|---|
| `0xFF` | reset: `rep = {1,2,4,8}`; produces no bytes |
| `0x00..0x7F` | literal run of `l = c + 1` bytes (1..128): copy `lit[lp..lp+l)` to output; `lp += l` |
| `0x80..0xBF` | repeat match: `ri = (c >> 4) & 3`, `lv = c & 15`; if `lv == 15` then `lv += varint(len)`; `l = lv + 6`; `dist = rep[ri]`; if `ri > 0`: shift `rep[1..ri] = rep[0..ri-1]`, `rep[0] = dist` |
| `0xC0..0xFD` | new match: `lv = c & 0x3F` (0..61); `l = lv + 6`; `dist = varint(off)`; `rep = {dist, rep[0], rep[1], rep[2]}` |
| `0xFE` | new match with long length: `lv = varint(len)`; then as above |

A match copies `l` bytes from `out - dist` to `out`, byte by byte in increasing order
(overlap is intended: `dist = 1` repeats one byte). Match length is always at least 6.

`varint(stream)`: unsigned LEB128 — bytes with the high bit set continue, 7 payload
bits each, least significant group first, at most 5 bytes and at most 31 bits (the 5th
byte has its high five bits clear). Reading past the slice end, a 6th byte or a value
above 31 bits is an error (2.6.7: the reference decoders refuse the block; until 2.6.6
they used the partial value).

A reader MUST reject the block if: a literal run would read past `lit_sz` or write past
`dst_size`; `dist == 0`; `dist > out` (would read before the block start); a match would
write past `dst_size`. A block that ends with `out != dst_size` is an error.

The encoder never emits a match whose source crosses the block start; distances are
therefore bounded by the block size, and a decoder needs no history from earlier
blocks. Which matches the encoder chooses (minimum lengths by distance, repeat
preference) is encoder policy and not part of the format.

## 3. The four streams as stored

Every stream is a self-describing sequence of chunks; each chunk is either a standard
zstd frame (RFC 8878, single frame, no dictionary) or raw bytes. This is what lets a
generic zstd decoder — including NVIDIA's nvCOMP batched zstd — decode the entropy layer
of an archive it has never seen. A chunk decodes to a known number of bytes; a reader
MUST reject a chunk that decodes to any other number or fails to decode.

### 3.1 Offset, length and command streams ("FSE layout")

    [0]       u64 word:  bits 0..47 = decoded size S; bits 48..62 = CHUNK / 4096; bit 63 = 0
    [8]       u64 cs[nc]           per-chunk entry: bits 0..47 stored size;
                                   bit 63 = stored raw; bit 62 = rANS chunk (§3.1.1);
                                   bits 48..61 reserved (0); 62 and 63 never both set
    [8+8*nc]  chunks, in order

`nc = ceil(S / CHUNK)`. Chunk `i` decodes to bytes `[i*CHUNK, min((i+1)*CHUNK, S))` of
the stream. Its stored size is `cs[i] & ~(1<<63)` when compressed and the decoded
length when raw; chunk `i` starts at the running sum of the preceding stored sizes.
`S` fits in 48 bits (256 TB per stream). CHUNK is a multiple of 4096.

A stream shorter than 8 bytes is empty (S = 0). This happens for tiny inputs.

A reader MUST check the whole chunk table before decoding: every entry well-formed and
`8 + 8*nc + sum(stored sizes) <= stored stream length`.

#### 3.1.1 rANS chunks (the zstd-free token profile, 2026-09-29)
A chunk whose entry has bit 62 set is a 32-lane interleaved static rANS stream (order 0,
12-bit probabilities, 32-bit states, 16-bit renormalisation), laid out as

    [32]     bitmap of present symbols (bit s of byte s/8)
    [..]     frequency of each present symbol, ascending, unsigned LEB128; sum = 4096
    [128]    32 initial states, u32, each in [2^16, 2^32)
    [4]      W, the number of 16-bit words
    [2W]     renormalisation words

Symbol `i` of the chunk belongs to lane `i mod 32`; groups of 32 symbols decode in order,
lanes ascending. Lane `l` decodes `slot = x & 4095`, the symbol `s` with
`cum[s] <= slot < cum[s] + f[s]`, then `x = f[s] * (x >> 12) + slot - cum[s]`, and if
`x < 2^16` takes the next word: `x = (x << 16) | w`. A reader MUST reject: frequencies
not summing to 4096, a state out of range, a read past W, unread words, or any lane not
ending at state 2^16. Reference code: `src/ax_rans.h` (the same file is `c/ax_rans.h`).
Writers emit rANS chunks only when asked for the profile (`AX_TOK=rans`; environment variables only in builds with
`ACEAPEX_ENV_TUNING`, the CLI - [ENVIRONMENT.md](ENVIRONMENT.md)); decoders
without §3.1.1 see a reserved-bit error.

LEGACY: a zero in bits 48..62 is an archive written before the chunk field existed
(before 2026-09-19). Its CHUNK is 524288 unless the writer was run with `FSE_CHUNK`, in
which case the reader must be told the same value. Conforming writers MUST set the field.

Token stream bounds (2.6.4): encoders MUST NOT write a token chunk (CHUNK, whether in the field or by the LEGACY rule)
above 16 MiB (16 777 216; the reference encoders write 524 288 and never above 16 MiB) nor a block whose slice of
`off`, `len` or `cmd` (its BlockOffsets size) is above `4 * block_size + 4096` bytes (a block's tokens are about
1.25 x the block at most). A decoder MAY refuse an archive that breaks either (the reference decoders do, with
`ACEAPEX_ERR_DATA`). Without them the streaming decoder's memory followed the stream sizes an archive declares (a
33 KB archive with 128 MiB chunks took 2.1 GB, `verify/repro/cpp_alloc/st_group.aet`); with them it follows
`block_size`.
Exceptions, as a fact: the CLI of the paper tag `paper6-v1` (b9e2910) and the research fork `aceapex_depth.cpp`
(outside every build, ADR-007) take `FSE_CHUNK` without the 16 MiB ceiling, so with that variable set by hand they
could write chunks above 16 MiB. Such archives carry 0 in the chunk field (LEGACY), and the released decoders since
v2.1.0 take 524 288 for that field (at most 16 MiB from `FSE_CHUNK` in tuning builds): they did not read those
archives before 2.6.4 either.

### 3.2 Literal stream

The first u64 word carries the decoded size `S` in bits 0..59 and three flags (bit 63 is reserved and MUST be 0):

| bit | meaning |
|---|---|
| 62 | zstd layout (§3.2.1 or §3.2.2). Clear = the stream uses the FSE layout of §3.1 (LEGACY: no released encoder writes it - 18 release tags 2.0 … 2.6.6; whole-archive readers accept it, the streaming and GPU readers MAY refuse it; bits 48..61 MUST be 0) |
| 61 | chunked layout (§3.2.2). Clear with bit 62 set = original 4-part layout (§3.2.1) |
| 60 | tagged chunks: each chunk starts with a mode byte (§3.2.3). Only with bit 61 |

A reader MUST reject flag combinations it does not know (bit 63 set; bit 60 without 61).

#### 3.2.1 Original layout (4 parts)

    [0]   u64 S | bit62
    [8]   u64 zsz[4]           stored size of each part
    [40]  four zstd frames

Part `t` decodes to `[t*P, min((t+1)*P, S))` with `P = ceil(S/4)`; a part beyond `S`
is empty (stored size 0) and decodes to nothing. `S = 0` is valid: four empty parts (2.6.7: every reference reader
accepts it). A reader MAY leave the stored bytes of a part beyond `S` unread.

#### 3.2.2 Chunked layout

    [0]    u64 S | bit62 | bit61 [| bit60]
    [8]    u64 CH                 chunk size in bytes: >= 65536 and a multiple of 4096
    [16]   u64 zsz[NW]            stored size of each chunk, NW = ceil(S / CH)
    [16+8*NW]  chunks, in order

Chunk `t` decodes to `[t*CH, min((t+1)*CH, S))`; every chunk is exactly `CH` bytes except
the last. NW is derived, never stored. Encoders fall back to §3.2.1 when NW would
exceed 65535. A reader MUST reject `CH < 65536`, `CH` not a multiple of 4096 and `NW > 65535` (2.6.7; no released
encoder writes them - 2 194 stored chunked archives checked).

#### 3.2.3 Tagged chunks (bit 60)

Each chunk begins with one mode byte; the remaining `zsz[t] - 1` bytes are:

- mode `0`: one zstd frame decoding to the chunk's `raw` bytes.
- mode `1`: the DNA pack of §3.3.
- mode `2`: the open DNA pack of §3.4 (zstd-free, 2026-09-29).
- mode `3`: open plain, one piece (§3.4) holding the chunk's `raw` bytes.
- other values are reserved and MUST NOT be written; the reference decoders read them as mode 0.
  Decoders older than §3.4 read modes 2 and 3 as mode 0, where they fail as zstd frames.

### 3.3 DNA pack (literal chunk, mode 1)

For a chunk of `raw` bytes whose content is mostly `A C G T` in either case:

    [0]   u32 nexc          number of exception bytes (anything that is not ACGT/acgt)
    [4]   u32 h1, h2, h3, h4   stored sizes of the four sub-frames below
    [20]  seq  zstd frame -> ceil(raw/4) bytes:  2 bits per base, MSB first, A=0 C=1 G=2 T=3
          cse  zstd frame -> ceil(raw/8) bytes:  1 bit per position, MSB first; 1 = lowercase
          gap  zstd frame -> nexc x u32 (h3 = 0 when nexc = 0): distance from the previous
               exception position (from 0 for the first), cumulative
          val  zstd frame -> nexc bytes (h4 = 0 when nexc = 0): the exception byte itself

A reader MUST reject `nexc > raw`, `20 + h1 + h2 + h3 + h4` above the chunk, `nexc > 0` with `h3` or `h4` = 0 (2.6.6) and
`nexc = 0` with `h3` or `h4` != 0 (2.6.7), and a sub-frame that does not decode to its stated size.

Reconstruction, in this order: `dst[i] = "ACGT"[(seq[i>>2] >> (6 - 2*(i&3))) & 3]` for
`i < raw`; then `dst[i] |= 0x20` where `cse[i>>3] & (0x80 >> (i&7))`; then `pos = 0;
for k in 0..nexc: pos += gap[k]; dst[pos] = val[k]`. An exception position `>= raw` is
ignored by the reference decoders. Exception bytes carry their own case; the mask bit at
an exception position is written by the encoder as the byte's own case and is
overwritten by `val` anyway.

### 3.4 Open DNA pack (literal chunk, mode 2) and pieces

The zstd-free literal profile (ADR-019). A **piece** is one mode byte and a payload whose
decoded length `n` is always known from the context: `0` = the `n` raw bytes (stored size
`1 + n`); `1` = one rANS chunk of §3.1.1 decoding to `n` bytes. Other piece modes are an
error. A piece of `n = 0` has stored size 0. Mode 3 is one piece of the chunk's `raw` bytes.

Mode 2 is the DNA pack of §3.3 with two parts recoded and every part a piece:

    [0]   u32 nexc          number of exception bytes (anything that is not ACGT/acgt)
    [4]   u32 ncse          bytes of the case-run stream
    [8]   u32 ngap          bytes of the gap stream
    [12]  u32 h1, h2, h3, h4   stored sizes of the four pieces below (h3 = h4 = 0 iff nexc = 0)
    [28]  seq  piece -> ceil(raw/4) bytes, as in §3.3
          cse  piece -> ncse bytes: run lengths, unsigned LEB128, alternating upper, lower,
               upper, ... and starting with upper; only the first run may be 0; they sum to raw
          gap  piece -> ngap bytes: nexc unsigned LEB128 gaps; exception k is at the running
               sum of gaps 0..k; only the first gap may be 0; every position < raw
          val  piece -> nexc bytes: the exception byte itself

Reconstruction is that of §3.3: bases, then `|= 0x20` over every lower run, then
`dst[pos_k] = val[k]`. The case rule of the writer is the same as for mode 1 (a byte in
`a..z` is lower). A reader MUST reject: `28 + h1 + h2 + h3 + h4` different from the stored
size, an unknown piece mode, a piece not decoding to its length, a LEB128 value over 32
bits or not terminated inside its stream, bytes left after the last run or gap, runs not
summing to `raw`, a zero run or gap where forbidden, a position `>= raw`, fewer than `nexc`
gaps. Reference code: `src/ax_lit_open.h` (the same file is `c/ax_lit_open.h`).
Writers emit modes 2 and 3 only for the open profile (`AX_LIT=open`, or `AX_PROFILE=open` - only in builds with
`ACEAPEX_ENV_TUNING`, [ENVIRONMENT.md](ENVIRONMENT.md) -
which also sets `AX_TOK=rans`); there every literal chunk is mode 2 or 3 (whichever is
smaller when the chunk qualifies for the DNA pack), and the literal stream is always the
tagged chunked layout. An archive of this profile contains no zstd frame.

## 4. Region reads

To produce original bytes `[offset, offset+length)`: blocks `b0 = offset / block_size`
through `b1 = (offset+length-1) / block_size`; for each stream, only the chunks covering
the union of those blocks' slices need decoding. Bytes outside the requested range are
never read by the block decoder. Block independence (§1.3) is what makes this exact.

Bytes that no block slice references - chunks of a decoded stream after the last slice, parts of §3.2.1 beyond `S` - are
not part of the original. A reader MAY leave them undecoded and unchecked; the reference whole-archive decoder happens to
decode every chunk (and so refuses a damaged unreferenced one), the region, streaming and C99 readers do not. Conformance
does not depend on either.

## 5. Integrity

`xxhash` is the XXH3-64 of the whole original input and lets a full decode be verified.
It does not cover a region read; the per-chunk zstd frames carry their own checksums
only if the writer enabled them (the reference writer does not), so a region reader's
guarantees are: every frame decoded to exactly the expected length, every bound above
held. An input that breaks a rule of this document (§8) MUST produce an error, never bytes. A damage that breaks no rule
(a changed literal byte inside a raw chunk, a flipped bit inside a zstd block) decodes to the declared size with other
bytes; only `xxhash` sees it. A reader that offers a whole decode SHOULD offer it with this check - the reference library:
`aceapex_decompress_ex` with `ACEAPEX_VERIFY_XXH3` (C++ and C99, 2.6.7), the streaming decoder with
`ACEAPEX_STREAM_VERIFY`, the CLI by default - and data from untrusted sources SHOULD be read only through it. The
reference decoders are fuzzed under ASan/UBSan (every push; 1 h before a release) with no crash and no verified wrong
output.

## 6. Versioning

`version` is 2 and has been since the first release; this document freezes what version
2 means. Version 3 (ACEAPEX 2.4.0) is the FAST profile, a different block layout under the
same magic and the same first 36 header bytes: [FORMAT_FAST.md](FORMAT_FAST.md). A future
incompatible change increments `version`; readers MUST reject versions
they do not implement (the 2.4.0 readers reject anything but 2 and 3). Flag bits in stream words are reserved: unknown set bits are an
error, not a hint. Compatibility rule: a reader of version N reads every archive of
version <= N; a writer writes only the version it declares.

## 7. Conformance

An implementation conforms if it decodes every file in `verify/fixtures/` to the
recorded SHA-256 and rejects the corrupted variants that `scripts/fixture_test.sh`
derives from them. `make test` runs this for the two reference decoders; a third
implementation can run the same script with `BIN=<its cli>`.

## 8. Refusal rules (2.6.7, SPEC-VAL-1)

Every rule by which a reader refuses a version-2 archive, in one place. MUST: a conforming reader refuses the archive (the
whole call fails, as the conventions at the top say). MAY: a reader may refuse; the reference readers do unless the row says otherwise.
"Region readers" decode a span of blocks (§4); "whole-archive readers" decode everything. The reference readers - the
C++ library, the C99 decoder (= the Python package) and the GPU library's host plan - follow every MUST row; the rules
were collected from their code, the differences found brought to one rule (2.6.7), and each tightened rule was checked
on 3 013 stored archives of every release (0 newly refused).

| # | rule | level | § |
|---|---|---|---|
| 1 | input below 68 bytes; magic other than `ACEPX2\0\0`; `version` other than 2 (3: [FORMAT_FAST.md](FORMAT_FAST.md)) - for the empty archive too | MUST | 1.1, 1.2, 6 |
| 2 | `block_size` = 0; `num_blocks * block_size < orig_size` or `(num_blocks - 1) * block_size >= orig_size` (num_blocks > 0) | MUST | 1.1 |
| 3 | header + table + any stream size beyond the input, each term checked | MUST | 1.1 |
| 4 | `num_blocks` = 0 unless `orig_size`, all four stream sizes are 0 and `block_size` != 0 | MUST | 1.2 |
| 5 | `block_size` above 64 MiB (also for the empty archive); a token chunk above 16 MiB; a token slice above `4 * block_size + 4096`; a decoded literal stream above `orig_size`; a decoded token stream above `4 * orig_size + 1 MiB` | MAY | 1.1, 3.1 |
| 6 | an empty archive at all (the GPU library: nothing to decode on a device) | MAY | 1.2 |
| 7 | a block slice outside its decoded stream (offset or size) | MUST | 1.1, 1.3 |
| 8 | block slices that do not follow each other; whole-archive readers check every entry, region readers MUST check the span and its two neighbours, MAY the whole table | MUST | 1.3 |
| 9 | token stream: bit 63 of its first word; an entry with bits 48..61 set or with bits 62 and 63 both set; a chunk table or chunk bodies beyond the stream | MUST | 3.1 |
| 10 | rANS chunk (§3.1.1): stored size below 164; a frequency LEB over 3 bytes or past the end; a present symbol of frequency 0; frequencies not summing to 4096; an initial state below 2^16; bytes after the words; a read past W; unread words; a lane not ending at 2^16 | MUST | 3.1.1 |
| 11 | literal stream: bit 63; bit 60 without bit 61; with bit 62 clear (LEGACY) any of bits 48..61 set | MUST | 3.2 |
| 12 | literal stream with bit 62 clear (LEGACY, never written by a release) - streaming and GPU readers | MAY | 3.2 |
| 13 | chunked literals: `CH` = 0, `CH < 65536`, `CH` not a multiple of 4096, `NW > 65535`; a table or chunk bodies beyond the stream; a chunk with bytes and stored size 0 | MUST | 3.2.2 |
| 14 | tagged chunk mode 0 or 4..255 that is not one zstd frame of the chunk's size; mode 3 piece framing (§3.4) | MUST | 3.2.3, 3.4 |
| 15 | DNA pack (mode 1): below 20 bytes; `20 + h1..h4` above the chunk; `nexc > raw`; `nexc > 0` with `h3` or `h4` = 0; `nexc` = 0 with `h3` or `h4` != 0; a sub-frame of another size | MUST | 3.3 |
| 16 | open DNA pack (mode 2): the rules of §3.4, and `ncse` = 0, `ncse > 5 * raw + 5`, `ngap > 5 * nexc`, `ngap < nexc`, `ngap` != 0 when `nexc` = 0 | MUST | 3.4 |
| 17 | a zstd chunk that is not exactly one zstd v1 frame (magic 0xFD2FB528) decoding to its size: a legacy (v0.x) or skippable frame, a second frame, a truncated frame | MUST | 3 |
| 18 | match layer: a literal run past `lit_sz` or `dst_size`; `dist` = 0 or `dist > out`; a match past `dst_size`; `out != dst_size` at the end; a varint cut by its slice, of 6 bytes or above 31 bits | MUST | 2 |
| 19 | bytes no block slice references (chunks after the last slice, §3.2.1 parts beyond `S`): a reader MAY leave them unchecked | MAY | 4 |
| 20 | `xxhash` different from the XXH3-64 of the decoded original - checked by a verified whole decode (§5); region reads cannot check it | MUST when verifying | 5 |

Not refusals: an exception position `>= raw` (§3.3, ignored); bytes left in a slice after `out == dst_size`; a 4-part
literal stream with `S` = 0 (four empty parts).
