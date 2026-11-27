# stream_hdr — stream-header rules the C99 decoder did not check (2.6.6)

Four copies of conformance fixtures (`gen.py`), each breaking one rule of FORMAT_ACEPX2 §3:

| archive | from | broken rule |
|---|---|---|
| `tok_bit63.aet` | dna_4096B | offset stream word 0, bit 63 set (§3.1: bit 63 = 0) |
| `litch_e63.aet` | dna_4096B | chunked literal stream, `zsz[0]` with bit 63 set (§3.2.2: stored sizes, no flag bit) |
| `lit4_e63.aet` | text_legacy4 | 4-part literal stream, `zsz[0]` with bit 63 set (§3.2.1) |
| `lit_tag_nochunk.aet` | text_legacy4 | 4-part literal stream with bit 60 (tagged) and a mode byte 0 before each part (§3.2: bit 60 only with bit 61) |

Found by the J3-K gate of 2.6.6 (C++ against C99 on the api_fuzz mutants, 27.11.2026): the C++ decoder refused such
archives, the C99 decoder (= the Python package's decoder) masked bit 63 or ignored the flags and decoded them - in the
mutants, to bytes different from the original. Since 2.6.6 the C99 decoder refuses all four on decompress, region and
dec_open + dec_region; the C++ decoder refuses them on all six entry points, as before.
Tests: `stream_hdr_c99.c` (negative control `-DAX_STREAM_HDR_NO_CHECK` = the 2.6.5 C99 decoder: all four decode to the full
size), `stream_hdr_test.cpp` (C++, the two decoders agree).
