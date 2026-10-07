# H4 - cohort anchors: how far would shared copy breaks take N = 50 (ESTIMATE, not a format)

Status: estimate from reading the 50 q16k v1 archives (read only, nothing encoded, format untouched). Run 2026-10-07 on
ace-core inside M6 windows without timing (N = 200 request phase 13:27 UTC: breaks; N = 200 integrity phase 14:11 UTC:
aggregation, silence gate held by a nice-19 keeper until done), 1 thread, nice 19. Archives: the first 50 manifest rows
(the N = 50 set of the AGC comparison), q16k.

## Method

- `h4breaks` (copy of the frozen v1 decoder 5b6d5ce + the H0 cost hooks): for every block, the ops in stream order with
  their cost (symbols log2(4096/f) + raw bits). EVENT = literal run (possibly empty) + the following copy (or a final
  literal run). BREAK = an event that is not the first of its block; its key = the T2T position where the previous
  reference copy ended (forward: end; reverse complement: start) x strand; its cost = the event's bytes (literals, kind,
  parameters, length). First events of blocks = "block start" (not coverable).
- Method check first, on 2 archives (`method_check_2.tsv`): break 11.51 MB + block start 0.34 MB + coder overhead
  (184 639 blocks x ~2.5 B = 0.46 MB) == payload 12.32 MB (y1_HG00438.1); the same identity holds for the 50
  (break 597.7 + start 16.9 + overhead ~23 = payload 637.6 MB).
- `h4agg`: frequency of a key = number of samples that have it. K anchors (K = 1, 2, 4, 8, greedy by size reduction)
  are kept as ordinary samples (full size counted). A non-anchor sample's break is COVERED if its key has frequency >= f
  and at least one anchor has the same key. A covered break costs `repl`:
  - repl = 0 - upper bound of the saving (the sample copies across the shared variant from the anchor for free);
  - repl = 3.191 B = mean cost of an exact-continuation copy event in the same archives (one copy event per covered
    break) - a conservative bound (in reality one switch serves a run of consecutive shared breaks; not measured).
- Sizes in MB per sample without block hashes; baseline = 13.1441 MB (q16k, N = 50; README AGC table: refrel3 q16k
  13.14, AGC with T2T 8.65).

## Shared breaks (`FREQ` lines of h4agg.out)

233 586 410 breaks (mean 2.56 B), 46 132 905 distinct keys; 11.95 MB per sample of the 13.14 are break events.
Break bytes by frequency: f = 1 (private) 1.25 MB/sample; f >= 2: 10.70 MB/sample; f >= 5: 8.62; f >= 10: 6.10;
f >= 25: 0.99 (sums of the FREQ rows).

## Table K, f -> MB per sample (no block hashes), ESTIMATE

| f | K = 0 | K = 1 | K = 2 | K = 4 | K = 8 |
|---:|---:|---:|---:|---:|---:|
| 2, repl 0 | 13.14 | 10.49 | 8.76 | **7.15** | **6.18** |
| 5, repl 0 | 13.14 | 10.59 | 8.92 | **7.48** | **6.74** |
| 10, repl 0 | 13.14 | 10.89 | 9.53 | **8.49** | **8.20** |
| 25, repl 0 | 13.14 | 12.48 | 12.29 | 12.25 | 12.30 |
| 2, repl 3.19 B | 13.14 | 12.36 | 11.90 | 11.52 | 11.29 |
| 5, repl 3.19 B | 13.14 | 12.38 | 11.96 | 11.60 | 11.44 |
| 10, repl 3.19 B | 13.14 | 12.46 | 12.12 | 11.88 | 11.83 |
| 25, repl 3.19 B | 13.14 | 12.91 | 12.84 | 12.83 | 12.84 |

Anchors chosen (repl 0, f = 2): K = 1 y1_HG02257.1, K = 2 + y1_HG01978.1, K = 4 + y1_HG02630.1, y1_HG00621.1, K = 8 + y1_HG00735.2,
y1_HG02886.1, y1_HG01071.2, y1_HG01928.2 (full names in h4agg.out). At f = 25 the greedy step can increase the
size (it must add K anchors; an anchor's full size counts).

## Conclusion (estimate)

- <= 8.65 MB per sample at N = 50 is reachable only in the upper bound: K = 4 at f = 2 (7.15), f = 5 (7.48) or f = 10
  (8.49); K = 2 at f = 2 gives 8.76 (just above). With one copy event per covered break (3.19 B, more than the mean
  break 2.56 B) no K <= 8 gets below 11.29.
- Where it lands depends on one unmeasured number: how many consecutive covered breaks one anchor switch serves (the
  run length of shared breaks along a sample). That is the next measurement for H4 (from the same break files: runs of
  covered keys in block order), before any format work; first on N = 5 as asked.
- Covering is by exact key (T2T position x strand of the copy end); shared variants whose copies end at different
  positions are not counted (the estimate can be low there), and copying from an anchor across a covered break is
  assumed exact (it can be high there).

## Refinement: one anchor switch per RUN of covered breaks (`h4runs`, same break files; ESTIMATE)

The conservative bound above charged one switch event (3.19 B) per covered break. `h4runs` walks every non-anchor
sample's breaks in stream order and counts runs of consecutive covered breaks: one switch per run (a block boundary
is not in the break files, so a run may span it - a slight overestimate of run length). Anchors = the greedy sets of
the repl-0 rows (full names in h4agg.out; e.g. f = 2, K = 4: y1_HG02257.1, y1_HG01978.1, y1_HG02630.1, y1_HG00621.1).

| f | K | covered breaks | runs | mean run | MB/sample, cost 0 | MB/sample, one switch per run |
|---:|---:|---:|---:|---:|---:|---:|
| 2 | 2 | 88.4 M | 24.5 M | 3.61 | 8.76 | **10.32** |
| 2 | 4 | 120.6 M | 27.2 M | 4.44 | 7.15 | **8.89** |
| 2 | 8 | 139.4 M | 23.1 M | 6.04 | 6.18 | **7.66** |
| 5 | 2 | 84.5 M | 24.8 M | 3.40 | 8.92 | **10.51** |
| 5 | 4 | 114.3 M | 29.2 M | 3.91 | 7.48 | **9.35** |
| 5 | 8 | 129.4 M | 25.8 M | 5.02 | 6.74 | **8.38** |
| 10 | 2 | 73.5 M | 26.0 M | 2.83 | 9.53 | **11.18** |
| 10 | 4 | 94.8 M | 30.6 M | 3.10 | 8.49 | **10.44** |
| 10 | 8 | 100.6 M | 29.6 M | 3.40 | 8.20 | **10.09** |

Run-length histogram (f = 2, K = 4): runs of 1 break 12.0 M, 2-3: 8.0 M, 4-7: 4.0 M, 8-15: 1.8 M, 16-31: 0.84 M, 32-63:
0.38 M, 64-127: 0.13 M, 128+: 0.03 M (`runs/runs_f2_K4.out`).

**Conclusion with the run model (estimate):** <= 8.65 MB per sample at N = 50 needs K = 8 anchors at f = 2 (7.66) or
f = 5 (8.38); K = 4 at f = 2 gives 8.89, just above. The remaining unknowns are the same as above (exact-key covering,
exact copying across a covered break) plus the cost of the switch itself (3.19 B is the mean exact-continuation copy
event of today's format; a cohort-dictionary pointer would be coded differently).

## (d) H1 and H3 from the H0 ledger (q16k, N = 50, same archives)

- H1 (compact block table): the meta section is 19.57 MB for 50 = 0.39 MB per sample (raw block table 22.10 MB of the
  22.96 MB raw meta). Upper bound of H1 on the no-hash size: 0.39 MB per sample (13.14 -> 12.75) if the table cost went
  to zero; block hashes (1.47 MB per sample q16k) are outside this table.
- H3 (models): payload fields per sample - copy lengths 6.06 MB (symbols 3.06 + raw 3.01), ABS positions 1.46 MB, DELTA
  1.10, literals 1.04, LL 0.76, kind 0.64, REP 0.73, coder overhead 0.46. Each 10 % less on the length field = 0.61 MB
  per sample; no model change was measured, so no H3 figure is claimed beyond this scale.
- Alone, H1 + H3 cannot reach 8.65 from 13.14 without removing ~4.5 MB of a 12.75 MB payload; H4 is the only one of the
  three whose upper bound reaches it.

## Reproduce

```
bash build.sh <dir>; g++ -std=c++17 -O2 h4runs.cpp -o <dir>/h4runs
<dir>/h4breaks ~/golden/genome/t2t.fa <out.brk dir> .wk/hprc_cohort/v1/<50 names>.q16k.rr3 > breaks50.tsv
<dir>/h4agg breaks50.tsv <out.brk dir> > h4agg.out
<dir>/h4runs breaks50.tsv <out.brk dir> <f> <anchor indices in breaks50.tsv order, comma-separated> > runs/runs_f<f>_K<K>.out
```
Outputs: breaks50.tsv (131f89e0...), h4agg.out (bc5562d4...); binaries h4breaks 5616d64b..., h4agg 7f373d05...
