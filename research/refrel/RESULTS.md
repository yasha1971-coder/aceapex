# refrel — HPRC assemblies as LZ77 against the decoded T2T reference (research, 2026-10-03)

Isolated research: nothing here changes ACEPX2, `src/`, the default archive bytes, the perf gate or its baselines. The
token stream and the literal stream of an assembly are written raw and compressed with the ACEAPEX CLI in the open
profile, so the literals are coded exactly as in open; the reader decodes them with `aceapex_decompress_region` (CPU)
or the library's windows call (GPU).

**Format** (`refrel_format.h`). The assembly's bases (records concatenated, upper case; case runs and line layout in a
small meta file) are cut into 16 KiB blocks. A match copies either from the reference (T2T-CHM13v2.0, resident and
decoded, upper case) at an absolute position, forward or **reverse complement**, or from earlier bytes of the same
block. Blocks never read another block. A reference copy that continues the previous one (SNP: one literal, then
"same place") costs one byte plus its length; a nearby jump (indel) a zig-zag delta; anything else an absolute
position with the strand in bit 0.

Host: ace-core (AMD EPYC 4344P, 8 cores / 16 threads), CLI 2.2.1-dev, libzstd 1.4.8. Input: the first four HPRC
year-1 haplotypes (`.fa.gz` sha256 == the index): HG00438.1, HG00438.2, HG00621.1, HG00621.2. Logs: `logs/`.

## 1. What is copied from the reference

| assembly | bases | from the reference | copies | mean copy, bases | of it reverse complement | self (in block) | literals |
|---|---:|---:|---:|---:|---:|---:|---:|
| HG00438.1 | 3 025 118 465 | 98.670 % | 4 660 291 | 640.5 | 52.9 % of all bases | 1.146 % | 0.184 % |
| HG00438.2 | 3 035 735 720 | 98.546 % | 4 632 737 | 645.7 | 50.0 % | 1.267 % | 0.188 % |
| HG00621.1 | 2 905 948 993 | 98.519 % | 4 546 791 | 629.7 | 57.5 % | 1.291 % | 0.191 % |
| HG00621.2 | 3 023 026 071 | 98.678 % | 4 540 343 | 657.0 | 62.5 % | 1.145 % | 0.178 % |

Tags (HG00438.1): continuation 2 283 485, delta 1 124 763, absolute 1 252 043, self 224 907. Ops per 16 KiB block:
mean 40-42, max 686-748 (`logs/ops-per-block-2026-10-03.log`).

The first version had no reverse-complement copies: 48.7-58.8 % from the reference, 39-49 % literals - HPRC contigs
come in either orientation (`logs/build-2026-10-03.log` holds the final run only; the first run is in CONTEXT).

## 2. Size per assembly

| assembly | refrel tokens | literals | meta | **refrel total** | open (.aet) | 2 bits / base | open / refrel |
|---|---:|---:|---:|---:|---:|---:|---:|
| HG00438.1 | 16 972 580 | 1 411 356 | 394 510 | **18 778 446** | 775 015 777 | 756 279 616 | 41.3 |
| HG00438.2 | 16 660 683 | 1 448 379 | 378 959 | **18 488 021** | 777 272 025 | 758 933 930 | 42.0 |
| HG00621.1 | 16 584 726 | 1 409 610 | 381 209 | **18 375 545** | 743 673 151 | 726 487 248 | 40.5 |
| HG00621.2 | 16 418 939 | 1 365 582 | 378 716 | **18 163 237** | 774 372 093 | 755 756 517 | 42.6 |

Plus the reference itself, once: T2T upper-case bases 3 117 292 070 B resident (as an open archive 853 265 321 B).

**AGC 3.2.4**, T2T as the first sample (16 threads; `logs/agc-2026-10-03.log`):

| collection | AGC archive, B | per added assembly |
|---|---:|---:|
| T2T alone | 707 323 301 | - |
| T2T + 2 HPRC | 760 754 520 | 26.7 MB (mean of 2) |
| T2T + 4 HPRC | 787 595 850 | 20.1 MB (mean of 4); the 3rd and 4th 13.4 MB each |

Without T2T (02.10, `research/logs/tools-2026-10-02.log`): +31.3 MB at N=2, +18.3 MB at N=4. refrel is 18.2-18.8 MB per
assembly whatever N is (every assembly against the reference only); AGC goes lower as the collection grows (it
also uses the other assemblies). Not measured: AGC at N = 10.

**Encode time** (16 threads): reference read 5.1 s + index of 389.7 M 32-mers 10.1 s, once; per assembly read 4.6-5.0 s,
parse **1.7 s**, CLI for both streams 0.08-0.09 s. Open archive of the same assembly: 6.2-6.4 s. AGC: T2T alone
46.7 s, +4 assemblies 15.9 s more. Peak RSS of `refrel build` with four assemblies 10.9 GB.

Where the bytes are: 90 % of a refrel archive is tokens, and the open profile compresses them only x1.25 (byte-aligned
LEB128 fields in one stream). The 1.25 M absolute positions of HG00438.1 alone are ~5 MB raw. Splitting the fields
into streams and predicting positions is the obvious next step (not done).

## 3. Decode

**Full decode == FASTA**, all four (1 thread, through the two archives): 10.2-11.4 s per assembly
(`logs/full-2026-10-03.log`); AGC `getset` of one assembly 2.0 s.

**Windows**, HG00438.1, random W-base windows (seed 20261003 + W), every window == the FASTA's bases; open = the same
bases from the open archive by region calls (FASTA bytes, line ends dropped). `logs/windows-cpu-2026-10-03.log`,
plot `curves_cpu.png`.

| W, bases | refrel 1 thr, w/s | open 1 thr, w/s | refrel 16 thr, w/s | open 16 thr, w/s | refrel 16 thr, GB/s | open 16 thr, GB/s |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 10 130 | 22 186 | 100 253 | 215 477 | 0.026 | 0.055 |
| 1 Ki | 9 800 | 21 889 | 99 340 | 211 770 | 0.102 | 0.217 |
| 4 Ki | 9 654 | 21 166 | 97 726 | 200 853 | 0.400 | 0.823 |
| 16 Ki | 9 301 | 17 986 | 92 736 | 167 254 | 1.519 | 2.740 |
| 64 Ki | 7 916 | 11 369 | 78 916 | 103 141 | 5.172 | 6.759 |
| 256 Ki | 5 126 | 4 642 | 48 641 | 41 543 | 12.751 | 10.890 |
| 1 Mi | 2 191 | 1 390 | 16 494 | 4 327 | 17.295 | 4.537 |

Small windows: refrel is 2.2x slower. A window makes two region calls (tokens, literals), and each decodes a 64 KiB
chunk of its stream although a refrel block needs ~114 B of tokens and ~30 B of literals (amplification). Large
windows: refrel is faster - most bytes are `memcpy` from the resident reference instead of entropy decoding.
Profile before the copy fix: 40 % in byte-wise op execution; memcpy + a complement table took W = 1 MiB from 0.385 to
2.30 GB/s on 1 thread. Tried: 4 KiB blocks for the two streams - 255 windows/s (regions decode far more; to be
understood separately, not pursued here).

GPU (refrel kernel on the card, ncu L2 hit rate, curves on the same card): `run_colab.sh`, not run yet - section 3b
is filled from `MyDrive/aceapex_logs/refrel_<date>.txt`.

## 4. Capacity on one card (arithmetic on measured sizes; GPU check in `run_colab.sh capacity`)

Per assembly on the card: the two archives (18.2-18.8 MB) + block spans (2 x 4 B per block, 1.5 MB) = 19.91 MB (mean
of the four). 2 GiB kept for decode buffers in every column; the other columns need no reference.

| card | reference resident | left for refrel | refrel assemblies | open (767.6 MB each) | 2 bits (749.4 MB) | raw FASTA (3.03 GB) |
|---|---:|---:|---:|---:|---:|---:|
| 80 GiB | 3.12 GB | 80.63 GB | 4 048 | 109 | 111 | 27 |
| 96 GiB | 3.12 GB | 97.81 GB | 4 911 | 131 | 134 | 33 |

The HPRC year-1 release (47 samples, 94 haplotype assemblies) would take ~1.9 GB beside the reference.

## 5. Literature (checked references)

* Kuruppu, Puglisi, Zobel. Relative Lempel-Ziv compression of genomes for large-scale storage and retrieval. SPIRE
  2010, LNCS 6393:201-206. doi:10.1007/978-3-642-16321-0_20 - RLZ: each genome as LZ77 factors of one reference.
* Engineering relative compression of genomes: arXiv:1103.2351; Reference sequence construction for relative
  compression of genomes: arXiv:1106.3791 (SPIRE 2011).
* Ferrada, Gagie, Gog, Puglisi. Relative Lempel-Ziv with constant-time random access. SPIRE 2014,
  doi:10.1007/978-3-319-11918-2_2.
* Hoobin, Puglisi, Zobel. Relative Lempel-Ziv factorization for efficient storage and retrieval of web collections.
  PVLDB 5(3):265-273, 2011. doi:10.14778/2078331.2078342, arXiv:1106.2587.
* Cox, Farruggia, Gagie, Puglisi, Sirén. RLZAP: Relative Lempel-Ziv with adaptive pointers. SPIRE 2016,
  arXiv:1605.04421 - the "continuation" idea of tags 0 / 1 here,
  as differentially coded pointers.
* Bille, Gørtz, Puglisi, Tarnow. Hierarchical relative Lempel-Ziv compression. SEA 2023, doi:10.4230/LIPIcs.SEA.2023.18,
  arXiv:2208.11371.
* Deorowicz, Danek, Li. AGC: compact representation of assembled genomes with fast queries and updates.
  Bioinformatics 39(3):btad097, 2023. doi:10.1093/bioinformatics/btad097.
* Gagie, Navarro, Prezza. Fully functional suffix trees and optimal text searching in BWT-runs bounded space (r-index).
  J. ACM 67(1), 2020. doi:10.1145/3375890, arXiv:1809.02792.
* Rossi, Oliva, Langmead, Gagie, Boucher. MONI: a pangenomic index for finding maximal exact matches. J. Comput. Biol.
  29(2):169-187, 2022. doi:10.1089/cmb.2021.0290.
* GPU random access into relatively compressed genomes: no work found besides our own arXiv:2606.18900 (absolute-
  offset LZ77, not relative to a reference). Hypothesis, not a claim of novelty.

What is not new: RLZ itself (2010), differential pointers (RLZAP), reverse-complement factors. What this measures:
RLZ blocks made independent (16 KiB, absolute reference offsets) so that a window decodes from its blocks alone, with
literals coded as in open and a GPU path; the size cost of that independence is the comparison with AGC above.
