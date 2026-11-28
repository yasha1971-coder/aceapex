[written by ChatGPT (AI) at the author's request; checked by the author]

# CROWN-2 — preregistration, 2026-11-28

Executor: this HW ChatGPT session only. Yakov explicitly authorized this work on
2026-11-28. Repository: aceapex, branch `research/crown2-bwt`, draft PR to `dev`;
no merge, release, external issue, or public performance announcement.
Base: fresh `dev` `9931ad0ab3f6f19fedf9a9b52a3e2893ad421eda`.
This file is the sole change in the first task commit, before any probe or run.

## Decision and finish

Yakov and ACEAPEX need to decide whether an independently implemented BWT-class
codec can replace bsc at its TB-LVL-0 density. Crown requires BOTH, on the exact
211,947,520-byte silesia.ref.tar:

- complete archive including headers, checksums, chain indices and stream tables
  <= 50,266,774 bytes;
- single-thread decompression > 75.48 decimal MB/s on ace-core EPYC 4344P,
  median of three round-robin paired passes against bsc in the same run.

Passing one axis is not a crown. An incomplete codec or an isolated phase win is
reported as such. Silesia is closed to selection: DEV-2 alone chooses the design.
The reference-only known-answer check is allowed to read Silesia; it cannot tune
the candidate. Candidate Silesia is evaluated only after a frozen final design.

## Read foundations and checked live state

- Owner's complete CROWN-2 task and HW prognoz-zadanie/external-text rules.
- ace-core `/home/aeterna/pubrepo/CLAUDE.md`; project context, roadmap, closed
  avenues, prior calibration and the DEV-2 LOCK located by read-only preflight.
- GitHub default branch is `dev`; live main is
  `ce6b6740c7aae8a01720d615ae024c181b7d52b6`. No existing crown branch or open
  CROWN PR was found before creating this branch. Existing ACE sessions' worktrees
  are not this executor's workspace.
- Accepted TB-LVL-0 baseline: TurboBench
  `4aa97c8c37311e399ea3e7782c18c652c5bdb69f`, libbsc
  `6542faafd0c235975e77e219c77f8227f770fe91`, bsc 0e0 = 50,266,774 bytes,
  75.475 MB/s on this host. The TurboBench archive used a 1 GiB outer block,
  effectively the complete 211,947,520-byte input; an 8 MiB-block archive is NOT
  assumed to have these same bytes. H2.1 phase blocks and final archive blocks
  are distinct registered scopes.
- Owner's phase observations: QLFC 51–60%, inverse BWT 40–49%; approximately
  5 bytes/symbol for inverse working data, 8 MiB -> about 40 MiB vs 32 MiB L3;
  four independent QLFC segments cost +0.12…0.63% bytes. These are supplied
  observations, not new measurements by this session.
- Important pre-run mechanism check: pinned libbsc already calls
  `libsais_unbwt_aux` (bwt.cpp calls at lines 348/350); its embedded libsais is
  2.12.2 and already has sampled-chain decoding. For an 8 MiB input the wrapper
  selects a 1 MiB sampling distance, approximately eight chains. H2.1 therefore
  tests a different representation/K/prefetch against an existing multi-chain
  implementation, not a serial strawman. No novelty claim follows from K chains.

## Frozen development inputs

Source: `/home/ubuntu/ACE_TRINITY_EVO/LAB/DEV2/blocks/`, read-only.
Authoritative LOCK:
`/home/ubuntu/ACE_TRINITY_EVO/LAB/XQBPB/repo/dev2/LOCK.md`, SHA256
`adba22c33dd65bdc30bb59eb7659113f543813cba803d9682f69e2c330350590`.
`blocks_sha256.txt` SHA256:
`82173dd593ad5b3468762b7271a26ffe0da8204a4cd2b88f4784815fa349055c`.

| Piece (exact filename) | Bytes | SHA256 |
|---|---:|---|
| d2_text_en | 8388608 | 046f85db05c0edd1febd35efc2da541dfe2df301463c0e2b157953228e733b86 |
| d2_text_src | 8388608 | b736b80247d5ff42850ab4f739743577eec3a132355ec7fccaac801aa7fe875a |
| d2_x86 | 8388608 | 0524f1ff5dff38664a8d49ee34fb3be6062ef96b5c865ac197a9573c188b83fe |
| d2_table_sdf | 4194304 | 95f2fed1bbb4cc09e1d15d64273696c34196c48780d7045fabb27cde0b44f1e2 |
| d2_table_db | 4194304 | 555aff149ccec419bdfd5479f86f49cab853a59349be33d776e3fd25f16c6de1 |
| d2_image | 4194304 | 45375150a801b0562e1ee934f71c16e70374b990ec3a0c526a9aff626f92d49b |
| d2_xml | 4194304 | 45b8a5ad4442c4ad5fd70f38fafcf27bf9ba31e5be6f75fdfbe68afd347b2d46 |

Total 41,943,040 bytes, one piece per block. Verify actual bytes against these
hashes before use. Preserve the originals. This task uses LOCK's inputs, not its
separate evolve-fast/kanzi acceptance rule: CROWN-2's comparator is bsc.
Final-only Silesia SHA256:
`a667bac80089b3d04d5496772149e632f0758974b0579d743cd8d6e5e0d63eb2`.

## Forecasts recorded before execution

| Event | Claude (owner-supplied, unchanged) | ChatGPT |
|---|---|---|
| H2.1 complete inverse-BWT phase >=1.5x bsc | 55% | 20%; expected geometric-mean phase speedup 0.75–1.20x |
| H2.2 entropy faster than QLFC with byte cost <=+0.5% | 30% | 15%; adapting probabilities and extra stream state compete with QLFC's specialized model |
| Both final crown axes within three weeks | 15% | 8%; density must survive an independently implemented entropy coder as well as the phase tradeoff |

H2.1 model: hiding independent dependent-load latency may improve chain walking,
but histogram/table construction and the baseline's existing eight-chain,
two-symbol path limit the gain. If inverse occupies 40–49%, even a 1.5x inverse
win alone yields only 1/(1-f+f/1.5) = 1.154–1.195x complete decoding, assuming
unchanged other phases and bytes. A phase ratio is not whole-codec throughput.

### H2.1 — first experiment

Own inverse BWT: independent sampled chains, interleaved in one thread, prefetch.
Own code is written from the permutation definition; libbsc is a separately pinned
reference dependency, not copied implementation. libsais may be used as an
Apache-2.0 library for forward BWT/SA. Initial library pin:
`b1aa1fde090e00a4e2030b9fb54198698b84e463` (2.12.2).

Fixed grid before data: K={1,4,8,16,32}, prefetch={off,on}, one DEV-2 piece per
block (4 or 8 MiB). Packed 24-bit links require n < 2^24; reject larger blocks
in this prototype instead of truncating links. Account for every sampled index
and format byte. K=1 is a self-control, not the bsc comparison row.

Primary metric: full inverse phase, including histogram/table construction,
allocation where required, chain traversal and output, identically bounded on
both sides. Forward transform, entropy decoding and file I/O are outside this
phase. Report own table-build and traversal subdivisions diagnostically; do not
compare own traversal-only timing with complete bsc inverse timing.

Three round-robin passes; alternate/reverse reference/candidate order by pass,
fixed rotation over grid and pieces. Each timed cell reconstructs at least
64 MiB by an integer number of complete repetitions of that piece. No timing
is used to choose the repeat count. Output bytes must equal the original on
every repetition; checks themselves are outside the inverse-phase timer.

Selection: maximize geometric mean of the seven per-piece bsc/own phase-time
ratios, each using three-pass medians; break exact ties by fewer stored metadata
bytes, then lower K, then prefetch off. Report each piece and a separate total-
bytes/total-time aggregate. H2.1 HIT requires >=1.5x geometric mean AND no piece
below 0.95x. Otherwise MISS. A correct smaller positive gain is still recorded,
not relabelled HIT. If no inverse configuration beats bsc, keep that negative
result and test H2.2 without claiming the chain idea has succeeded. H2.2 and
H2.3 require new numerical per-run registrations before their probes.

## Method gates, before main timing

1. Positive control: repeated identical input produces identical serialized
   representation, and all configurations restore exact bytes.
2. Every actual decode is a round trip and verified byte-for-byte, with input,
   archive/representation and restored SHA256 logged.
3. Negative controls: corrupt payload/checksum and invalid chain indices must
   be rejected with failure; truncated input and excessive lengths fail without
   unbounded allocation. Corruption must not silently yield success.
4. Known-answer gate, reference only: retained pinned TurboBench static binary
   SHA256 `351ea9edf86f3cdaf222bcc54146260e8eea42efaee00ae81a589f0838f4204b`
   must reproduce bsc 0e0 50,266,774 bytes and an ace-core median within
   [70,82] MB/s (the prior registered interval around 75.5). Three passes,
   one thread, same host/core/command. At most one complete repeat if outside
   the interval; otherwise BLOCKED: reference drift. Never tune to pass it.
5. A/A phase control: two identical reference lanes must differ by <5% in their
   three-pass medians. If not, the performance comparison is invalid.
6. Baseline and candidate must decode the same original piece. Distinct BWT
   encodings are allowed only with equal function, complete phase boundaries
   and all stored side information disclosed; no uncharged prebuilt inverse
   table. Cross-check own output against independent forward/reference bytes.

## Places, admission, exclusions and costs

- Correctness, byte and instruction probes run only in GCP `aceapex-bench` on a
  C4 SPOT VM. Set max-run-duration <=2h, instance-termination-action DELETE,
  auto-deleting boot disk; no persistent data disk. Register exact instance,
  machine, zone, source SHA, input hashes, price source/rate, start/end times,
  elapsed billable estimate and dollars in the result log before starting work.
  Initial cloud authorization envelope for this registered attempt: one
  c4-standard-4, <=2 VM-hours, estimated spend <=US$2. If the documented rate
  cannot meet the envelope, stop before provisioning. Retain cloud receipts
  before deleting only the task-owned VM, and confirm its VM/disk are absent.
  Other projects/sessions' instances and disks are never stopped or deleted.
- ace-core is the sole speed machine: CPU0 pinned, one thread, archives and
  outputs in RAM; no long build under the shared benchmark lock.
- All timed work uses `flock /run/lock/ovh-bench.lock`; if occupied, wait.
  Record UTC date, /proc/loadavg, nproc, CPU/kernel/governor and /proc/stat
  boundary snapshots. Admission: load1-T<=1.0 and no foreign process >10% of
  one CPU, T=0 before start. Boundary rule during single-thread timing:
  load1>2.0 means LOADED. Record other-core utilization as data, not a verdict.
- Keep every attempt, including excluded attempts. Retake only the same loaded
  unit, same piece/grid/order, maximum three attempts. After three LOADED
  attempts stop BLOCKED: load with top process names. No time-based exclusion.
- Spot preemption/crash is an interrupted attempt, preserved and excluded.
  No accepted cell is repeated for a favorable result. A method defect stops
  execution for diagnosis and a separately committed amendment before retry;
  do not silently reinterpret the forecast or the measurements.
- Checkpoint source and raw evidence with SHA256. No run before the relevant
  preregistration commit is durable and its exact SHA is logged by the runner.

## Report after each hypothesis

STATUS; source/calibration/input/environment hashes; all attempt counts;
table of complete bytes, decimal MB/s and matched phases against bsc;
forecast / fact / HIT or MISS; exclusions; cloud hours/$ and cleanup receipts.
Do not manufacture a complete-archive ratio or whole-codec speed for H2.1.
Codec code review is performed by the executor before each code commit.

Fact: NOT RUN. No VM, correctness probe, instruction probe or timer has run for
this task before this registration. Subsequent facts are appended with their
actual source and evidence commits; these pre-run forecasts stay unchanged.

### Pre-run buffer-scope clarification

Before either phase timer, prepare an equally sized mutable output buffer from
the retained BWT bytes. The public bsc inverse is in-place and normally receives
entropy output in this buffer. Its reference timer calls that in-place inverse,
not a const-image wrapper that would add an artificial full-BWT copy. Own decode
reuses the same prepared output size. Histogram/permutation workspace allocation,
construction, traversal and workspace release stay inside the complete inverse
timer on both sides. Container parsing, buffer preparation and byte comparison
are outside both timers. No probe has executed before this clarification.
Each host phase cell first performs one untimed, byte-verified inverse warmup on
that same representation before the fixed-byte timed repeats. This initializes
the reference library in that process and applies the same warmup to our code.
H2.1 compares inverses of the raw DEV-2 pieces, without claiming the same work
volume as bsc's complete filtered/entropy-coded archive pipeline.
