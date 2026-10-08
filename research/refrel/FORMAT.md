# refrel3 v1 - container format (research; frozen as v1 on 2026-10-04 by the user's decision)

One file per assembly. An assembly is stored as edits against a **decoded reference** (T2T-CHM13v2.0 for the HPRC
dataset); every block of Q bases decodes alone. Reference implementation: `refrel3v1.cpp` (encode / decode / fetch /
info), entropy coding `refrel3.h` (`r3_decode_stream`), GPU decoder `refrel3_gpu.cu`. Datasets: **q4k** (Q = 4096,
default) and **q16k** (Q = 16384).

All integers little-endian. XXH3 = XXH3_64bits (xxHash 0.8, seed 0). SHA-256 = FIPS 180-4.

## 1. Header (136 bytes)

| offset | size | field |
|---:|---:|---|
| 0 | 8 | magic `RFRL3V1\0` |
| 8 | 4 | version = 1 |
| 12 | 4 | Q, block size in bases: 1024, 2048, 4096 or 16384 (anything else: refuse) |
| 16 | 4 | flags: bit 0 = per-block XXH3 present; other bits must be 0 |
| 20 | 4 | reserved, 0 |
| 24 | 32 | SHA-256 of the decoded reference: its records' bases concatenated in file order, upper case, no headers and no line ends |
| 56 | 8 | number of bases of that reference |
| 64 | 8 | n, bases of the assembly (records concatenated, case kept) |
| 72 | 8 | number of blocks = ceil(n / Q) |
| 80 | 8 | XXH3 of the source FASTA file bytes (headers and line ends included) |
| 88 | 8 | XXH3 of the assembly base stream (case kept) |
| 96 | 8 | meta section bytes (one zstd frame) |
| 104 | 8 | meta bytes after decompression |
| 112 | 8 | block-hash section bytes: 8 x blocks if flag bit 0, else 0 |
| 120 | 8 | payload bytes |
| 128 | 8 | **header XXH3** (mandatory): XXH3 of bytes [0, payload start) with these 8 bytes taken as 0 |

Then: u16 length L + L bytes of the reference name (informational; the SHA-256 is what binds), the meta frame, the
block-hash section, the payload. File size = 138 + L + meta + hashes + payload exactly.

## 2. Meta (after zstd decompression)

1. u32 record count; per record: u32 name length, name bytes (the FASTA header line without `>`), u64 length in bases,
   u32 line width (bases per line; the last line of a record may be shorter). This is the **contig table**: the base
   offset of a record is the sum of the lengths before it; fetch by coordinates maps `name:start-end` (1-based,
   inclusive, name = header up to the first space or tab) to bases [offset + start - 1, offset + end).
2. u64 lower-case run count; per run LEB128 gap from the previous run's end, LEB128 length (bases in the assembly).
3. Model tables: for each of the 61 contexts of `refrel3.h` (`R3_ALPHA[c]` symbols each), LEB128 frequency per symbol;
   every context sums to 4096 or is all zero.
4. u64 block count is in the header; per block: LEB128 payload length of its rANS stream; LEB128 start state
   zz(c - predicted) x 2 + strand, predicted = previous block's c + Q (forward) or - Q (reverse complement), first block 0.

## 3. Block-hash section (flag bit 0)

Per block, 8 bytes: XXH3 of the block's decoded bases before lower-case runs are applied (upper case).

## 4. Payload

Per block, its rANS stream (`refrel3.h`: 24-bit state, 3 bytes flushed, static per-assembly tables of section 2.3),
decoded by `r3_decode_stream` with blen = min(Q, n - b x Q), the block's start state, and the reference. Events:
literal count, literals (contexts by the reference base the current diagonal predicts / order-2), kind (continue /
delta / recent diagonal / absolute / self / other strand at a cached locus), parameters, length - 12.

## 5. Checks (a reader refuses or fails, never guesses)

On open, before any decode: magic, version, Q in the allowed set, flags, section sizes add up to the file size, block
count = ceil(n / Q), block-hash section size, **header XXH3**, **reference SHA-256 and size equal to the loaded
reference** (else refuse: wrong reference), meta frame size and decompression, contig lengths sum to n, case runs inside
n, every model context sums to 4096 or 0, block lengths sum to the payload. On decode: every rANS stream consumed
exactly with the final state, every copy inside the block / reference; with checks on, every block's XXH3 (if present)
and the XXH3 of the rebuilt FASTA against the header.

## 6. Versioning

A reader accepts version 1 only. Any change of the layout, the model contexts or the entropy coder is a new version;
v1 archives stay decodable by a v1 reader.
