#!/usr/bin/env python3
"""gen.py - the archives of verify/repro/stream_hdr (2.6.6, J3-K of the 2.6.6 gates): copies of conformance fixtures with
one stream-header rule of FORMAT_ACEPX2 broken. The C++ decoder refused each of them already; the C99 decoder (and the
Python package, the same file) until 2.6.5 masked or ignored the bits and decoded them.
  tok_bit63.aet       dna_4096B, offset stream word 0 with bit 63 set (3.1: bit 63 = 0)
  litch_e63.aet       dna_4096B, chunked literal stream, zsz[0] with bit 63 set (3.2.2: stored sizes, no flag bit)
  lit4_e63.aet        text_legacy4, 4-part literal stream, zsz[0] with bit 63 set (3.2.1)
  lit_tag_nochunk.aet text_legacy4, 4-part literal stream with bit 60 set and a mode byte 0 put before each part, the
                      stored sizes and zlit_sz grown to match (3.2: bit 60 only with bit 61) - read as tagged it decodes
Usage: python3 verify/repro/stream_hdr/gen.py (from the repository root; rewrites the .aet files of this directory)"""
import struct
def load(name):
    b = bytearray(open(f"verify/fixtures/conf/{name}.aet", "rb").read())
    assert b[:6] == b"ACEPX2" and struct.unpack_from("<I", b, 8)[0] == 2
    nb = struct.unpack_from("<I", b, 24)[0]; zl = struct.unpack_from("<Q", b, 36)[0]
    return b, 68 + 64 * nb, zl                      # archive, start of the literal stream, its stored size
def orq(b, at, bit): v = struct.unpack_from("<Q", b, at)[0]; assert not (v >> bit) & 1; struct.pack_into("<Q", b, at, v | (1 << bit))
def put(name, b): open(f"verify/repro/stream_hdr/{name}.aet", "wb").write(b)
b, L, zl = load("dna_4096B"); h = struct.unpack_from("<Q", b, L)[0]; assert (h >> 60) & 7 == 7
c = bytearray(b); orq(c, L + zl, 63); put("tok_bit63", c)               # offset stream follows the literal stream
c = bytearray(b); orq(c, L + 16, 63); put("litch_e63", c)               # [0] S|flags, [8] CH, [16] zsz[0]
b, L, zl = load("text_legacy4"); h = struct.unpack_from("<Q", b, L)[0]; assert (h >> 60) & 7 == 4
c = bytearray(b); orq(c, L + 8, 63); put("lit4_e63", c)                 # [0] S|bit62, [8] zsz[0]
zsz = struct.unpack_from("<4Q", b, L + 8); body = L + 40; parts = []
for t in range(4): parts.append(b"\0" + bytes(b[body:body + zsz[t]]) if zsz[t] else b""); body += zsz[t]
assert body == L + zl
lit = struct.pack("<Q", h | (1 << 60)) + struct.pack("<4Q", *(len(x) for x in parts)) + b"".join(parts)
c = bytearray(b[:L]) + lit + b[L + zl:]; struct.pack_into("<Q", c, 36, len(lit)); put("lit_tag_nochunk", c)
