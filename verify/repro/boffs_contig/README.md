# boffs_contig — block slices that do not follow each other (2.6.6)

Three copies of the conformance fixture `text_200K` (13 blocks; `gen.py`) with one BlockOffsets entry damaged so that a
block's literal slice no longer starts where the previous block's ends:

| archive | damage |
|---|---|
| `last_lit0.aet` | block 12 (the last): `lit_off` = 0 |
| `mid_lit0.aet` | block 6: `lit_off` = 0 |
| `mid_lit_shift.aet` | block 6: `lit_off` = block 5's `lit_off` |

Every slice stays inside its decoded stream, so all checks of 2.6.5 passed them and the decoders returned success with
another block's literals - the silent wrong outputs of the J3-K gate on candidate 18e6da5 (12 of 12 were of this kind:
api_fuzz op 6 zeroed bytes of the table). In 2.6.5 this reached the C++ decompress / mt / stream (and the CLI
`d --out -`), the C++ region for a damaged block inside the span, and the C99 decoder (= the Python package). The CLI
writing a file refused it by the archive's XXH3.

Since 2.6.6 block b's slices must start where block b-1's end and block 0's at 0 - the running sums every encoder writes
(2 485 stored archives, 3.69 M blocks, all of them so). The C++ decompress / mt / stream / CLI and the C99 decoder check
the whole table; C++ region and ranges check the span and its two neighbours (a region read does not read the table of
the whole archive). Tests: `boffs_contig_test.cpp` (C++), `boffs_contig_c99.c` (C99); negative control
`-DAX_BOFFS_CONTIG_NO_CHECK` (2.6.5): the wrong bytes come back with success.
