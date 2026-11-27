#!/usr/bin/env python3
"""gen.py - the archives of verify/repro/boffs_contig (2.6.6, J3-K of the 2.6.6 gates): copies of the conformance fixture
text_200K (13 blocks, default profile) with one BlockOffsets entry damaged so that block b's slices no longer start where
block b-1's end - the 12 silent wrong outputs of the J3-K run on candidate 18e6da5 were all of this kind (api_fuzz op 6
zeroed 1-16 bytes of the table). Each slice stays inside its decoded stream, so every check of 2.6.5 passed it, and
decompress / mt / stream returned success with another block's bytes.
  last_lit0.aet       block 12 (the last): lit_off = 0
  mid_lit0.aet        block 6: lit_off = 0
  mid_lit_shift.aet   block 6: lit_off = the start of block 5's literal slice
(damaged token offsets mostly fail in the match decoder; literal offsets give the silent output)
Usage: python3 verify/repro/boffs_contig/gen.py (from the repository root; rewrites the .aet files of this directory)"""
import struct
b = bytearray(open("verify/fixtures/conf/text_200K.aet", "rb").read())
assert b[:6] == b"ACEPX2" and struct.unpack_from("<I", b, 8)[0] == 2
nb = struct.unpack_from("<I", b, 24)[0]; assert nb == 13
E = lambda k: 68 + 64 * k                                    # entry k: lit_off, off_off, len_off, cmd_off, 4 sizes
def put(name, c): open(f"verify/repro/boffs_contig/{name}.aet", "wb").write(c)
c = bytearray(b); assert struct.unpack_from("<Q", c, E(12))[0] != 0; struct.pack_into("<Q", c, E(12), 0); put("last_lit0", c)
c = bytearray(b); assert struct.unpack_from("<Q", c, E(6))[0] != 0; struct.pack_into("<Q", c, E(6), 0); put("mid_lit0", c)
c = bytearray(b); o5 = struct.unpack_from("<Q", c, E(5))[0]; assert o5 != struct.unpack_from("<Q", c, E(6))[0]
struct.pack_into("<Q", c, E(6), o5); put("mid_lit_shift", c)
