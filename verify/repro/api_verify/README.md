# api_verify — the checked whole decode (2.6.7, API-CHK-1)

Three conformance fixtures with one bit flipped (`gen.py`): `text_200K_p972.aet` and `dna_4096B_p177.aet` (default
profile), `text_fast_200K_p102.aet` (fast profile). Each decodes with success through `aceapex_decompress` / `_mt` (C++)
and `aceapex_decompress` (C99) to the declared size with 49, 46 and 460 wrong bytes - the same bytes in both decoders. No
structural check can see such a damage; the archive's only content checksum is the XXH3-64 of the whole original.

`aceapex_decompress_ex(..., ACEAPEX_VERIFY_XXH3)` (C++ library and C99 decoder) and `Archive.decompress(verify=True)`
(Python) refuse all three with `ACEAPEX_ERR_DATA` / `DecodeError`; every conformance fixture verifies.
Tests: `api_verify_test.cpp` (C++), `api_verify_c99.c` (C99), `api_verify_py.py` (Python on the C99 library). Negative
control `-DAX_VERIFY_NO_CHECK`: the flag is accepted and ignored - the wrong bytes come back with success.
