"""make_strict.py <repro work dir> <out dir> - two refusal fixtures for the checks where FORMAT_V1_SPEC.md is stricter than
the frozen v1 reader (not shipped; its outputs are):
  zero_context.rr3     asmB.q4k.hash.rr3 with every frequency of context 59 (FLIP: which cached diagonal; used once in
                       the archive, only symbol 0) set to 0 - a legal all-zero context, but a valid stream reads a symbol
                       from it; payload untouched; meta rebuilt (zstd level 19, content size), header XXH3 recomputed
  meta_two_frames.rr3  asmD.q16k.nohash.rr3 with an empty zstd frame (content size 0) appended to the meta section; meta
                       content identical; meta_bytes and header XXH3 updated (spec section 4: exactly one frame)
XXH3 through XXH3_BIN (as specdec.py)."""
import os, struct, sys
import zstandard
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specdec as S

W, OUT = sys.argv[1], sys.argv[2]; os.makedirs(OUT, exist_ok=True)


def split(a):
    L = a[136] | a[137] << 8; mz, mr, hs = (int.from_bytes(a[o:o + 8], "little") for o in (96, 104, 112))
    m0 = 138 + L
    return bytearray(a[:m0]), a[m0:m0 + mz], a[m0 + mz:m0 + mz + hs], a[m0 + mz + hs:], mr


def join(head, mz, mr, hs, payload):
    head[96:104] = struct.pack("<Q", len(mz)); head[104:112] = struct.pack("<Q", mr)
    b = bytearray(head + mz + hs); b[128:136] = bytes(8); b[128:136] = struct.pack("<Q", S.xxh3(b))
    return bytes(b + payload)


def meta_tables_offset(M):
    i = 4; nrec = int.from_bytes(M[:4], "little")
    for _ in range(nrec):
        hl = int.from_bytes(M[i:i + 4], "little"); i += 4 + hl + 12
    nr = int.from_bytes(M[i:i + 8], "little"); i += 8
    for _ in range(2 * nr): _, i = S.leb(M, i)
    return i


# 1. zero context
a = open(os.path.join(W, "arch", "asmB.q4k.hash.rr3"), "rb").read()
head, mzb, hs, payload, mr = split(a); M = zstandard.ZstdDecompressor().decompress(mzb)
i = meta_tables_offset(M); vals = []
for c in range(61):
    for s in range(S.ALPHA[c]):
        j = i; v, i = S.leb(M, i); vals.append((c, s, j, i, v))
assert [v for c, s, _, _, v in vals if c == 59] == [4096, 0, 0, 0]
c59 = [x for x in vals if x[0] == 59]
M2 = M[:c59[0][2]] + b"\x00" * 4 + M[c59[-1][3]:]                  # four LEB128 zeros instead of 4096,0,0,0
open(os.path.join(OUT, "zero_context.rr3"), "wb").write(join(head, zstandard.ZstdCompressor(level=19, write_content_size=True).compress(M2), len(M2), hs, payload))

# 2. two frames in the meta section
a = open(os.path.join(W, "arch", "asmD.q16k.nohash.rr3"), "rb").read()
head, mzb, hs, payload, mr = split(a)
empty = zstandard.ZstdCompressor(level=19, write_content_size=True).compress(b"")
open(os.path.join(OUT, "meta_two_frames.rr3"), "wb").write(join(head, mzb + empty, mr, hs, payload))
print("zero_context.rr3: context 59 zeroed in asmB.q4k.hash.rr3; meta_two_frames.rr3: empty frame of", len(empty), "B appended in asmD.q16k.nohash.rr3")
