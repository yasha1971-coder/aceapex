#!/usr/bin/env python3
"""gen.py - the archives of verify/repro/hdr_version (2.6.6, J3 of the 2.6.6 gates): copies of two conformance fixtures
(verify/fixtures/conf/dna_4096B.aet, default profile; text_200K.aet, default profile) with the header version field
(bytes 8..11, u32 little-endian) set to 0, 1, 4 and 0x0000CE02 (the value the J3 fuzz run met). Version 2 is the only
version of this path; 3 is the fast profile. The C++ library before 2.6.6 read every one of them as version 2.
Usage: python3 verify/repro/hdr_version/gen.py (from the repository root; rewrites the .aet files of this directory)"""
import struct
for src in ("dna_4096B", "text_200K"):
    b = bytearray(open(f"verify/fixtures/conf/{src}.aet", "rb").read())
    assert struct.unpack_from("<I", b, 8)[0] == 2
    for v in (0, 1, 4, 0xCE02):
        c = bytearray(b); struct.pack_into("<I", c, 8, v)
        open(f"verify/repro/hdr_version/{src}_v{v:x}.aet", "wb").write(c)
