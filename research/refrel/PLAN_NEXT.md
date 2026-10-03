# refrel — next step (plan, not run)

## A. Scale: 20-50 real HPRC assemblies resident on one card, windows across the cohort

Goal: measured residency and windows/s for a real cohort (not arithmetic), AGC on the same assemblies.

1. **Data** (ace-core): the first 50 haplotypes of the HPRC year-1 index (`Year1_assemblies_v2_genbank.index`), `.fa.gz`
   sha256-checked as `gpu_run.sh` does; ~0.87 GB each -> ~44 GB in `.wk/` (198 GB free). Download time depends on the
   S3 link; the 4 assemblies of 02.10 came at roughly 1 GB per minute or better - ~45-60 min for 50.
2. **refrel encode** (ace-core, 16 threads), one assembly at a time to keep the disk small: gunzip (~15 s) -> parse
   (1.7 s, one T2T index for all) -> CLI on both streams (0.1 s) -> delete the FASTA. ~25 s per assembly, **~20 min for 50**.
   Full decode == FASTA for every one (10 s each, 1 thread; 16 in parallel: ~1 min) before anything is measured.
3. **AGC 3.2.4 on the same set** (ace-core): `agc create` T2T + 20, T2T + 50 from the `.fa.gz` (AGC reads gzip); from
   02.10/03.10, T2T alone 47 s and ~4 s per added assembly -> ~4 min for 50. Size per added assembly at N = 20 and 50 next
   to refrel's (refrel does not change with N). Also AGC without T2T at N = 20 / 50 (as on 02.10).
4. **GPU** - the refrel archives of 50 assemblies are ~1 GB, T2T 3.1 GB:
   * code (ace-core, ~150 lines in `refrel_gpu.cu`): a `cohort` mode - all assemblies' archives and block spans resident,
     every batch splits its windows over the assemblies (one library windows call per stream per assembly, as
     `scripts/gpu_cohort.cu` does with streams; one refrel kernel launch over all (window, block) pairs with a per-pair
     assembly index); checks: 64 windows per assembly per W against the FASTA (kept on the host as `.fa.gz`, read once).
   * where: the archives have to reach the card. Colab: the VM would download 44 GB again (or the user copies ~1 GB of
     archives to Drive - nothing leaves ace-core by itself). RunPod H100: same download on the pod's fast link, or `scp`
     of 1 GB from ace-core by the user. Card time: upload + 7 W x (refrel, open) batches ~10-15 min; with the download
     on the GPU host ~1-1.5 h. Colab units are scarce (QUICK only) -> **RunPod H100 for this run** is the cheaper place,
     or Colab only if the 1 GB of archives is put on Drive first.
   * against: the same 50 as open archives on the card - 50 x 770 MB = 38 GB, fits on 80 GB (cohort of 10 on 03.10:
     7.71 GB); this gives refrel vs open windows/s at equal cohort size.
5. Output: `research/refrel/RESULTS.md` section "cohort", logs in `research/refrel/logs/`.

Estimated total: ace-core ~1.5 h (download-bound), GPU host ~15 min (archives present) to ~1.5 h (download on the host).

## B. Tokens: 90 % of the archive, open compresses them x1.25

Now: one byte stream per assembly, LEB128 fields interleaved (head, delta / absolute / distance, length). HG00438.1:
4.66 M reference copies, of which 1.25 M absolute (~5 MB raw), 1.12 M delta, 2.28 M continuation; 16.97 MB after open.

1. **Fields into separate streams + rANS per stream** (lowest risk): heads, lengths, deltas, absolute positions,
   self distances each in its own stream (chunked per block range as now), so each has its own statistics; lengths
   and deltas get small alphabets. Decoder change only in refrel (parse reads 5 cursors). Expected: the biggest part
   of x1.25 -> x2-3 on lengths / heads; positions stay costly.
2. **Positions predicted from the diagonal**: an assembly contig maps to the reference along a diagonal (ref - asm
   position ~ constant, or ref + asm ~ constant for reverse complement). Code an absolute position as a delta from the
   block's diagonal, the diagonal stored once per block in the meta (2-4 B per block instead of a 4-5 B position per
   jump; the meta is loaded with the archive, blocks stay independent). Targets the 1.25 M absolute tags (~5 MB raw).
3. **Edits instead of copies** (as an alignment): most tokens are "1 literal + continue" (SNP) - code a block as edits
   against its diagonal: (gap to next edit, edit kind SNP / ins / del / jump, base or length) with an adaptive
   context model (rANS with per-kind contexts, order-1 on the previous edit kind). This is the RLZAP / VCF-like view;
   most work, largest expected gain. Literature first (RLZAP adaptive pointers, AGC's own coding) before writing it.

Measure each on the 4 local assemblies (no new data needed): size, full decode == FASTA, CPU windows at W = 256 and
4 KiB; keep the format research-only. Estimated: (1) half a day, (2) half a day, (3) 2-3 days.
