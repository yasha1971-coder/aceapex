# dna_exc — DNA pack (literal chunk mode 1) with exceptions but no exception frames (2.6.6)

`dna_exc_h3h4zero.aet` (1 318 B, default profile level 1, 4 096 B of DNA with exceptions) is `dna_exc_intact.aet` with two
bytes of the literal chunk's DNA-pack header set to 0: h3 (gap frame size) 22 -> 0 and h4 (val frame size) 17 -> 0, nexc > 0
unchanged. FORMAT_ACEPX2 3.3: h3 = h4 = 0 only when nexc = 0. Found by the J3-K gate of 2.6.6 (C++ against C99 on the
api_fuzz mutants, 27.11.2026): both decoders returned 4 096 bytes, different from each other and from the original - the C++
decoder took the exception positions and bytes from an unwritten heap buffer, the C99 decoder put zeros in. The GPU plan
refused it already. Since 2.6.6 every C++ entry point and the C99 decoder refuse it; `dna_exc_intact.aet` still decodes.
Tests: `dna_exc_test.cpp` (C++), `dna_exc_c99.c` (C99, = the Python package's decoder); negative control `-DAX_DNA_EXC_NO_CHECK`.
