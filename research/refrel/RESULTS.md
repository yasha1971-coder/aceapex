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

### 3b. GPU (Colab, RTX PRO 6000 Blackwell Server Edition, 95.0 GiB; commit 6ea4fff)

`research/refrel/run_colab.sh`, compiled and run on the first attempt; excerpt of the log in
`logs/colab-blackwell-2026-10-03-excerpt.txt`, plot `curves_gpu.png`. HG00438.1; T2T resident decoded (3.12 GB); refrel
archives 16.97 + 1.41 MB + block spans 1.48 MB; open archive 775.02 MB. 10 batches per W back to back; 64 windows of
the last batch per W compared with the FASTA - all ok. On the VM (48 threads): T2T index 4.0 s, parse 0.65-0.69 s per
assembly, refrel full decode 3.6 s (1 thread); token and literal archive sizes equal to ace-core's, meta.zst
1.5-18.0 KB larger (another libzstd).

| W, bases | windows per batch | refrel windows/s | refrel GB/s | open windows/s | open GB/s | refrel / open | host us per batch (refrel) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 65 536 | 4 182 820 | 1.071 | 5 721 709 | 1.465 | 0.73 | 568.8 |
| 1 Ki | 65 536 | 4 073 932 | 4.172 | 5 646 117 | 5.782 | 0.72 | 578.8 |
| 4 Ki | 65 536 | 3 495 918 | 14.319 | 5 335 537 | 21.854 | 0.66 | 612.3 |
| 16 Ki | 32 768 | 2 179 053 | 35.702 | 3 171 030 | 51.954 | 0.69 | 415.9 |
| 64 Ki | 8 192 | 820 377 | 53.764 | 1 326 425 | 86.929 | 0.62 | 210.1 |
| 256 Ki | 2 048 | 234 972 | 61.597 | 425 642 | 111.580 | 0.55 | 161.5 |
| 1 Mi | 512 | 61 962 | 64.972 | 98 965 | 103.772 | 0.63 | 149.4 |

Last column (6th field of an `RGWIN refrel` line after the kind): host time per batch in microseconds - the selection
done on the CPU for refrel (blocks of each window, token / literal spans, the list of (window, block) pairs); open does
its selection on the card. It falls with W because a batch holds fewer windows (65 536 -> 512).

refrel on the card is 0.62-0.73 of open in windows/s at every W (open = FASTA bytes through the library's windows
call; refrel = bases, two windows calls for the streams plus the copy kernel). Peak 65.0 GB/s (refrel, W = 1 MiB)
against 111.6 GB/s (open, W = 256 KiB). Not in the excerpt: the ncu metrics (L2 hit rate) - section left open.

## 2b. Token model, step A (refrel2.cpp, refrel_v2.h; v1 format and GPU path unchanged)

Ideas 1 and 2 of `PLAN_NEXT.md` on the same four assemblies (`logs/v2-*.log`). **split**: the token fields in six
streams (heads, literal escapes, lengths - 12, deltas, absolute positions, self distances), each compressed alone by the
CLI (open profile). **carry**: every block starts from a stored state (reference pointer + strand, delta-coded against
the previous block's state moved by 16 KiB, in the meta) instead of (0, forward); encoded in two passes (the second
starts every block where the first pass's previous block ended). The meta of v2 stores spans as LEB128, which alone
makes it 40-50 KB smaller than v1's.

| variant | HG00438.1 | HG00438.2 | HG00621.1 | HG00621.2 | mean | vs v1 |
|---|---:|---:|---:|---:|---:|---:|
| v1 (one stream, no state; v2 meta) | 18 736 061 | 18 463 609 | 18 335 164 | 18 135 876 | 18 417 678 | - |
| split | 17 681 239 | 17 473 251 | 17 344 063 | 17 146 063 | 17 411 154 | -5.5 % |
| carry | 17 920 514 | 17 635 576 | 17 557 461 | 17 313 983 | 17 606 884 | -4.4 % |
| **split + carry** | **16 967 727** | **16 750 515** | **16 664 038** | **16 431 535** | **16 703 454** | **-9.3 %** |

split + carry, HG00438.1, bytes after the CLI: lengths 6 670 291, absolute positions 4 314 612, deltas 1 713 074, heads
1 656 878, literals 1 384 586, meta 926 202 (spans of seven streams 1.32 MB raw; block states 0.25 MB raw), self
distances 298 379, escapes 3 705. Carry turns 214 k absolute copies into continuations (1 252 043 -> 1 037 848
absolute) and doubles the parse (1.7 -> 3.4 s, two passes). Full decode == FASTA for all four (split + carry,
4.6-4.9 s on 1 thread, `logs/v2-full-2026-10-03.log`).

**CPU windows** (HG00438.1, windows/s, quiet machine after the HPRC download; `logs/v2-windows-cpu-2026-10-03.log`), all == FASTA:

| W | v1, 1 thread | split + carry, 1 thread | ratio | v1, 16 threads | split + carry, 16 threads | ratio |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 10 024 | 2 946 | 0.29 | 74 169 | 24 504 | 0.33 |
| 1 Ki | 9 809 | 2 988 | 0.30 | 89 868 | 28 302 | 0.31 |
| 4 Ki | 9 853 | 2 981 | 0.30 | 98 013 | 30 125 | 0.31 |
| 16 Ki | 9 347 | 2 750 | 0.29 | 92 925 | 27 942 | 0.30 |
| 64 Ki | 7 963 | 2 423 | 0.30 | 78 880 | 24 123 | 0.31 |
| 256 Ki | 5 196 | 1 891 | 0.36 | 48 715 | 19 161 | 0.39 |
| 1 Mi | 2 176 | 1 222 | 0.56 | 16 664 | 11 478 | 0.69 |

The 9.3 % costs 2.5-3.4x in windows/s: a window now makes seven region calls (six token streams + literals) instead of
two, and each decodes a 64 KiB chunk of its stream. With streams as separate ACEPX2 archives the split does not pay
for random access; it would need one container in which a block range's pieces of all fields sit together (or
per-stream chunks far smaller than 64 KiB, which on 03.10 behaved badly, see section 3). Not adopted.

Reading: the fields have different statistics, but the gain is modest; what is left is the **lengths** (4.66 M of them,
~1.4 B each after rANS) and the **absolute positions** (~4.2 B each). Both are the alignment itself: the distance to
the next difference and where a jump goes. Idea 3 (edits with a context model) targets exactly these two; AGC's
13.4 MB per further assembly at N = 4 is below this (16.4-17.0 MB) because it also uses the other assemblies.

## 4. Capacity on one card (arithmetic on measured sizes; GPU check in `run_colab.sh capacity`)

Per assembly on the card: the two archives (18.2-18.8 MB) + block spans (2 x 4 B per block, 1.5 MB) = 19.91 MB (mean
of the four). 2 GiB kept for decode buffers in every column; the other columns need no reference.

| card | reference resident | left for refrel | refrel assemblies | open (767.6 MB each) | 2 bits (749.4 MB) | raw FASTA (3.03 GB) |
|---|---:|---:|---:|---:|---:|---:|
| 80 GiB | 3.12 GB | 80.63 GB | 4 048 | 109 | 111 | 27 |
| 96 GiB | 3.12 GB | 97.81 GB | 4 911 | 131 | 134 | 33 |

The HPRC year-1 release (47 samples, 94 haplotype assemblies) would take ~1.9 GB beside the reference.

**Measured on the card** (Blackwell, `refrel_gpu capacity`): the four assemblies take 19.86 / 19.59 / 19.41 / 19.26 MB
(archives + block spans), mean 19.532 MB; reference 3.117 GB; free 94.43 -> 91.52 -> 91.44 GiB. Rows of the tool
(cap x GiB - reference - 2 GiB, divided by the mean): **4 128** assemblies on 80 GiB, **5 008** on 96 GiB.

**Beside a model** (loader_reality, same card: ~98.4 M parameters, bf16, context 8192, batch 8, peak 24.13 GiB ->
55.87 GiB left on an 80 GiB card): (55.87 GiB - 3.117 GB reference) / 19.532 MB per assembly
= (55.87 - 2.903) GiB / 0.01819 GiB = **2 912** assemblies (2 802 if 2 GiB more are kept for window decoding).
The formula as sent, (55.87 - 3.117 x 0.931) / 0.0195, gives 2 716: it divides GiB by the per-assembly size in GB
(0.0195 GB = 0.0182 GiB). Same row from loader_reality: open 71, 2 bits 78, raw FASTA 19 assemblies. At batch 32
(peak 92.03 GiB) nothing fits on 80 GiB.

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
