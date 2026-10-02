# Notes for a format v3 (not decided; ACEPX2 stays as it is)

Measured candidates, each with its bits, what it breaks, coordinate access and the GPU. Numbers from
`results/reality-2026-10-02.log` and `results/pangenome-2026-10-02.log` (ace-core, 2026-10-02). Nothing here is
implemented in the format; the prototypes are tuning-build tools with their own containers.

## R1. Reference blocks (pangenome)

**What.** A block may copy from a *reference segment*: a few blocks of an earlier member of the same archive (another
assembly), forward or reverse-complemented, virtually placed before the block. Matches then reach into the segment
exactly as into the block's own history (the distance counts from the end of the segment).

**Bits.** Per block a reference entry: member (varint, 1 B), orientation (1 bit), first block (varint, 2-3 B), block
count (2 bits for <= 3): about 4 B, against 64 B of the block entry; the prototype stores 11 B raw. Distances grow to
segment + block (<= 4 MiB: still 3-4 varint bytes). Measured (prototype `scripts/refseg.cpp`, AX_REFSEG): HPRC
HG00438.1 + HG00438.2 + HG00621.1, 9.08 GB: 2 141 MB (ACEAPEX 2.3, one archive per assembly) -> 968 MB (ratio 9.38);
the 2nd assembly 724 -> 176 MB, the 3rd 692 -> 95 MB. AGC 3.2.4: 754 MB. Missing to AGC: blocks with no segment found
(15 % of HG00438.2), one segment per block (a block over a breakpoint copies one side), exact matches only (every SNP
ends a match: R2), 1 MiB blocks.

**Compatibility.** ACEPX2 decoders must refuse such archives (a version 3 header, or a feature bit they check): a
match reaching before its block is a corrupt archive for them, and they stop on it (`dist > out`). A v3 decoder reads
every ACEPX2 archive unchanged. Container: a directory of members (name, line model, block range, reference column);
a member refers only to earlier members, depth <= D fixed by the encoder (the prototype: 2).

**Coordinate access.** Block b of member j needs its segment's blocks first, and theirs: measured 3.32 blocks on
average, 12 at most (depth 2, segments of <= 3 blocks; the bound is 1 + 3 + 9). Reverse complement: one pass over the
decoded segment (or a copy kernel that reads backwards and complements).

**GPU.** All members' outputs live in device memory, so a match copies from either the block's own output or the
referenced member's output: a second source pointer in the copy, no extra pass, except the dependency order (decode
the referenced members first: depth + 1 waves, or a batch plan that includes the reference blocks it needs).
Reverse-complemented segments: an RC buffer in temp, or the backwards complementing copy.

## R2. Match with substitutions

**What.** A match token that also carries n substitutions: after the copy, n bytes are replaced (position gap varint,
the new base). Targets the diverged repeat copies (soft-masked repeats are 34 % of T2T's bytes and 35 % of its bits,
at 2.13 bits/byte - the same as unique sequence) and SNPs against a reference (R1).

**Bits.** New command class (a cmd byte value ACEPX2 does not use) + a fifth stream of edits. Offline estimate
(`scripts/approx_est.cpp`, matches >= 32 bases, a substitution 10 bits + 4 per token with any): chr1 1 MiB blocks
k=4 substitutions per 100 b +2.0 %, k=8 +3.0 % of the archive (6 bits per substitution: +2.5 / +4.4 %); T2T +2.0 / +2.9 %
by the model, ~1.2 / 1.7 % after calibrating the model's exact matches against the real encoder (it overrates T2T 1.7x);
16 KiB blocks about half (chr1 +0.7 / 1.3 %).

**Compatibility.** New cmd values and a fifth stream: version 3, ACEPX2 decoders refuse. Blocks stay independent.

**Coordinate access.** Unchanged (block-local).

**GPU.** The block decoder applies a token's edits after its copy: n scattered byte stores per token, the edit stream
is one more stream in the plan (its chunks decoded like the token streams).

## Measured alongside (smaller changes, same version bump)

- **R0 line model.** FASTA line ends break matches at a different line phase. One line per record + a line model
  (a few bytes per record): T2T -4.72 %, chr1 -3.78 % with today's encoder; with a 12-byte head table (AX_HASH12)
  -5.50 % / -4.36 %. HPRC: 2 141 -> 2 063 MB. Access by coordinate: the line model maps FASTA offsets to sequence
  offsets (per record: header length, line width, sequence length).
- **R3 block table.** 64 B per block is 1.53 % of T2T at 16 KiB blocks (76 % of what 16 KiB blocks cost against
  256 MiB). Sizes only (offsets are prefix sums): superblocks of 64 blocks with 4 x u16 sizes per block 8.5 B/block
  (-1.30 %, O(1) access); by column + zstd 0.84 B/block (-1.48 %).
- **R4 literal chunks.** The encoder caps the chunked literal layout at 65 535 chunks (~4 GiB of literals); above it
  the pre-2.1 layout is used (three human assemblies in one file: ratio 3.36 instead of 4.24) and the stream decoder
  cannot take it. The decoders read the chunk count from the sizes; lifting the cap changes archive bytes for such
  inputs only (decision pending, ROADMAP).
