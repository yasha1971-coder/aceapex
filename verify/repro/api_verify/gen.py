#!/usr/bin/env python3
"""gen.py - the archives of verify/repro/api_verify (2.6.7, API-CHK-1): conformance fixtures with one bit flipped (byte
p ^= 0x01). Each still decodes with success through aceapex_decompress / _mt (C++) and aceapex_decompress (C99) - to the
declared size, but with wrong bytes, the same in both decoders: a damage no structural check can see, only the archive's
XXH3-64 of the original. Found by trying p from the end of the block table on (28.11.2026).
  text_200K_p972.aet       default profile, 49 bytes of the output wrong
  text_fast_200K_p102.aet  fast profile (header version 3), 460 bytes wrong
  dna_4096B_p177.aet       default profile, DNA pack, 46 bytes wrong
Usage: python3 verify/repro/api_verify/gen.py (from the repository root; rewrites the .aet files of this directory)"""
for src, p in (("text_200K", 972), ("text_fast_200K", 102), ("dna_4096B", 177)):
    b = bytearray(open(f"verify/fixtures/conf/{src}.aet", "rb").read()); b[p] ^= 1
    open(f"verify/repro/api_verify/{src}_p{p}.aet", "wb").write(b)
