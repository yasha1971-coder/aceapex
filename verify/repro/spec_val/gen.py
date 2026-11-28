#!/usr/bin/env python3
"""gen.py - the archives of verify/repro/spec_val (2.6.7, SPEC-VAL-1): one archive per reader rule made one rule in 2.6.7
(FORMAT_ACEPX2 8). Each breaks exactly that rule and is otherwise an archive the decoders of 2.6.6 accepted (the negative
controls of the tests decode it).
  empty_v7.aet        verify/fixtures/empty.aet with version 7 (D1: the C++ in-memory paths returned 0 for any version)
  empty_bs128m.aet    the same with block_size 128 MiB (D2)
  lit_ch32k.aet       text_767B, chunked literal CH 65536 -> 32768 (D7: CH >= 65536; NW stays 1)
  lit_ch65636.aet     text_767B, CH -> 65636, not a multiple of 4096 (D6)
  zstd_multi.aet      text_767B, its literal chunk (mode 0) followed by a second, empty zstd frame (D8: one frame per chunk)
  varint_cut.aet      dna_open_4097B, the last byte of the offset stream (a raw chunk) with its continuation bit set: the
                      last varint is cut by the slice end (D9)
  dna_noexc_h3.aet    dna_noexc_intact.aet (70 000 random ACGT, `aceapex c --level 1 --threads 1` of this tree; DNA packs
                      with nexc = 0), an empty zstd frame added as the gap frame of the last chunk, h3 = 9 (D18)
  trunc100.aet        text_767B cut to 100 bytes (D13: a region read of 0 bytes still checks the archive)
  bs128m.aet          dna_4096B (one block) with block_size 128 MiB (D3, GPU plan; the CPU decoders refused it since 2.6.4)
  tokch17m.aet        text_767B, offset stream chunk field 4097 x 4096 = 16 MiB + 4 KiB (D3, GPU plan; nc stays 1)
Usage: python3 verify/repro/spec_val/gen.py (from the repository root; rewrites the derived .aet files of this directory)"""
import struct
D = "verify/repro/spec_val"
EMPTY_FRAME = bytes.fromhex("28b52ffd2000010000")      # zstd v1 frame of 0 bytes, no checksum (`zstd --no-check` of nothing)
def rd(p): return bytearray(open(p, "rb").read())
def put(n, b): open(f"{D}/{n}.aet", "wb").write(b)
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]
def lit(b):                                             # start of the literal stream and its stored size
    return 68 + 64 * u32(b, 24), u64(b, 36)

e = rd("verify/fixtures/empty.aet"); assert u32(e, 24) == 0
c = bytearray(e); struct.pack_into("<I", c, 8, 7); put("empty_v7", c)
c = bytearray(e); struct.pack_into("<I", c, 20, 128 << 20); put("empty_bs128m", c)

t = rd("verify/fixtures/conf/text_767B.aet"); L, zl = lit(t)
h = u64(t, L); assert (h >> 60) & 7 == 7 and u64(t, L + 8) == 65536 and (h & ((1 << 60) - 1)) < 32768
c = bytearray(t); struct.pack_into("<Q", c, L + 8, 32768); put("lit_ch32k", c)
c = bytearray(t); struct.pack_into("<Q", c, L + 8, 65636); put("lit_ch65636", c)
z0 = u64(t, L + 16); body = L + 24; assert body + z0 == L + zl and t[body] == 0      # one chunk, mode 0, the last bytes of the stream
c = t[:L + zl] + EMPTY_FRAME + t[L + zl:]; struct.pack_into("<Q", c, L + 16, z0 + 9); struct.pack_into("<Q", c, 36, zl + 9); put("zstd_multi", c)
c = bytearray(t[:100]); put("trunc100", c)
O = L + zl; w = u64(t, O); assert u32(t, 24) == 1 and ((w >> 48) & 0x7fff) >= 1 and (w & ((1 << 48) - 1)) <= 4096   # offset stream: one chunk
c = bytearray(t); struct.pack_into("<Q", c, O, (w & ((1 << 48) - 1)) | (4097 << 48)); put("tokch17m", c)

g = rd("verify/fixtures/conf/dna_open_4097B.aet"); L, zl = lit(g); O = L + zl; zo = u64(g, 44)
w = u64(g, O); S = w & ((1 << 48) - 1); assert (u64(g, O + 8) >> 63) == 1 and 8 + 8 + S == zo       # one raw chunk: its bytes are the stream
last = O + zo - 1; assert not (g[last] & 0x80)
c = bytearray(g); c[last] |= 0x80; put("varint_cut", c)

n = rd(f"{D}/dna_noexc_intact.aet"); L, zl = lit(n); h = u64(n, L); assert (h >> 60) & 7 == 7
S = h & ((1 << 60) - 1); CH = u64(n, L + 8); NW = (S + CH - 1) // CH; tab = L + 16; pos = tab + 8 * NW
for k in range(NW - 1): pos += u64(n, tab + 8 * k)
zt = u64(n, tab + 8 * (NW - 1)); assert n[pos] == 1 and u32(n, pos + 1) == 0 and u32(n, pos + 13) == 0 and pos + zt == L + zl
c = n[:L + zl] + EMPTY_FRAME + n[L + zl:]; struct.pack_into("<I", c, pos + 13, 9)
struct.pack_into("<Q", c, tab + 8 * (NW - 1), zt + 9); struct.pack_into("<Q", c, 36, zl + 9); put("dna_noexc_h3", c)

b = rd("verify/fixtures/conf/dna_4096B.aet"); assert u32(b, 24) == 1
c = bytearray(b); struct.pack_into("<I", c, 20, 128 << 20); put("bs128m", c)
