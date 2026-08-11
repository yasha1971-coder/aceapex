# ACEPX2 — stream layout

What is written where, taken from the source rather than from memory. Two defects in
one evening came from the encoder and the decoder disagreeing about this layout, so it
is written down: a chunk count stored where a chunk size was expected, and a per-chunk
size formula inherited from a different scheme. Both were invisible until an archive
left the process that produced it.

All integers are little-endian. Offsets are byte offsets from the start of the file
unless stated otherwise.

## Archive

    [0]                    AetHeader, 68 bytes, packed
    [68]                   BlockOffsets x num_blocks, 64 bytes each
    [68 + 64*num_blocks]   literal stream,  zlit_sz bytes
    [...]                  offset stream,   zoff_sz bytes
    [...]                  length stream,   zlen_sz bytes
    [...]                  command stream,  zcmd_sz bytes

### AetHeader — 68 bytes, `#pragma pack(1)`

| offset | size | field | note |
|---|---|---|---|
| 0 | 8 | magic | `ACEPX2\0\0` |
| 8 | 4 | version | 2 |
| 12 | 8 | orig_size | uncompressed length |
| 20 | 4 | block_size | 16384 by default; `ACEAPEX_BS` overrides |
| 24 | 4 | num_blocks | ceil(orig_size / block_size) |
| 28 | 8 | xxhash | XXH3-64 of the original input |
| 36 | 8 | zlit_sz | compressed size of the literal stream |
| 44 | 8 | zoff_sz | offset stream |
| 52 | 8 | zlen_sz | length stream |
| 60 | 8 | zcmd_sz | command stream |

`sizeof(AetHeader)` is 68, not 72: without the pack pragma the compiler pads it and
every stream pointer shifts by four bytes.

### BlockOffsets — 64 bytes per block

    uint64_t lit_off, off_off, len_off, cmd_off;   // starts, in the UNPACKED streams
    uint64_t lit_sz,  off_sz,  len_sz,  cmd_sz;    // sizes

Starts first, then sizes. Offsets are exclusive prefix sums and address the streams
**after** entropy decoding, not their compressed form. A block is decoded from four
ranges and nothing else, which is what makes a region read possible.

## Stream headers

The offset, length and command streams share one layout; literals have two.

### Offset, length, command

    [0]        uint64  orig_size          uncompressed length of this stream
    [8]        uint64 x nc                compressed size of each chunk
    [8+8*nc]   chunks

nc = ceil(orig_size / 524288); chunks hold 512 KB of uncompressed data. Bit 63 set in
a size entry means the chunk is stored raw — the low bits are then the uncompressed
length and the payload is copied rather than decoded. Chunk i covers uncompressed
bytes [i*524288, min((i+1)*524288, orig_size)), and its file position is the running
sum of the preceding compressed sizes.

### Literal stream, original layout

    [0]        uint64  orig_size | bit62
    [8]        uint64 x 4                 compressed size of each part
    [40]       four parts

Bit 62 selects zstd rather than the chunked path above. The parts are equal shares,
ceil(orig_size / 4), the last holding the remainder. This is the default and what the
published measurements use.

### Literal stream, chunked layout

    [0]        uint64  orig_size | bit62 | bit61
    [8]        uint64  chunk_size         in bytes, chosen at encode time
    [16]       uint64 x nc                compressed size of each chunk
    [16+8*nc]  chunks

Bit 61 marks this layout. nc = ceil(orig_size / chunk_size) is derived, not stored, so
the two cannot disagree. Every chunk is exactly chunk_size except the last, which is
the remainder; a formula that special-cases the last *index* rather than the final
*chunk* passes on some inputs and fails on others.

The chunk size lives in the file. An earlier revision read it from the environment,
so an archive decoded correctly only in a shell with the same variable set. Nothing
about decoding may depend on the reader's environment.

Enabled by `LIT_CHUNK=<bytes>` at compression time, minimum 65536. It exists for
region reads: with the original layout a 16 KB region needs a quarter of the literal
stream unpacked; with 1 MB chunks it needs one chunk. An older build reading a chunked
archive fails cleanly rather than producing wrong bytes.

## Compatibility

Bits 63, 62 and 61 of the first stream word are flags; the rest is the size. A reader
that does not know a flag must fail rather than guess, since these bits sit inside
what an older reader treats as a length. Old archives are read unchanged and legacy
remains the encoder default.

## What a region read touches

For `length` bytes at `offset`: blocks floor(offset / block_size) through
floor((offset+length-1) / block_size), and in each of the four streams only the chunks
covering those blocks' ranges.

At 16 KB blocks and 512 KB entropy chunks a 16 KB request unpacks about 2 MB, roughly
128 times what was asked for, against the 209 MB a full decode unpacks. This is
measured. Read amplification is bounded by the chunk size, so a figure near 1.0 would
require chunks near the block size, which costs ratio — see CLAIMS.md for the trade at
1 MB literal chunks.
