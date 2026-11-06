# CRASH-2 — preregistered memory hypothesis (2026-11-06, ace-core, TurboBench v2026.11.06.164 / aceapex b67c858)

Hypothesis: on enwik9 the default-profile `aceapex` needs much more memory than `aceapex_fast`; with limited RAM this
can end in OOM or an unhandled allocation failure.
Prediction (yasha-context ACEAPEX/CALIBRATION.md 1dcaba0, before the measurement): at least one aceapex 1-4 profile on
enwik9 has Max RSS > 7 GiB; aceapex_fast 1 has Max RSS < 4 GiB.

Max RSS is the whole TurboBench process (`/usr/bin/time -v`): TurboBench's own buffers are in it (input n, compressed
buffer 1.3 n + 10 MB, decompressed copy). TurboBench `-U` reports C MEM / D MEM 0 for these codecs (its counter does not
see their allocations), so `time -v` is the measure.

## Step 1 — unconstrained, one process per codec / level / threads (`step1/`, `step1.sh`)

All 20 runs: rc 0 and the `-C4` check passed. Max RSS, GiB:

| codec | level | silesia.tar t1 / t4 | enwik9 t1 / t4 |
|---|---|---:|---:|
| aceapex | 1 | 1.40 / 1.34 | 6.54 / 6.13 |
| aceapex | 2 | 1.39 / 1.33 | 6.53 / 6.12 |
| aceapex | 3 | 1.54 / 1.43 | **7.21** / 6.67 |
| aceapex | 4 | 1.39 / 1.33 | 6.53 / 6.12 |
| aceapex_fast | 1 | 1.09 / 1.23 | 4.98 / 5.66 |

## Steps 2-4 — under MemoryMax (`limited/`, `limited.sh`)

Each run in its own named systemd user scope (`systemd-run --user --scope -u crash2-<codec>-<level>-t<t>-<limit>-r<n>
-p MemoryMax=<limit> -p MemorySwapMax=0`). Saved per run: command, `memory.max` / `memory.swap.max` read inside the scope
(the parent slices are `max`, so this is the effective limit), rc, `time -v`, stdout/stderr, journal, `memory.events`,
`memory.events.local`. Host swap: 2 x 512 MiB, excluded by MemorySwapMax=0.

| MemoryMax | aceapex 3 t1, enwik9 | aceapex_fast 1 t1, enwik9 (control) |
|---|---|---|
| 16G | rc 0, -C4 pass, oom 0 | rc 0, pass, oom 0 |
| 12G | rc 0, pass, oom 0 | rc 0, pass, oom 0 |
| 8G | rc 0, pass, oom 0 (2/2) | rc 0, pass, oom 0 (2/2) |
| 7G | **SIGKILL, oom 1, oom_kill 1 (2/2)** | rc 0, pass, oom 0 (2/2) |
| 6G | SIGKILL, oom_kill 1 | rc 0, pass |
| 5G | SIGKILL, oom_kill 1 | rc 0, pass |
| 4G | SIGKILL, oom_kill 1 | SIGKILL, oom_kill 1 |

Under 7G aceapex 3 is killed in the decompression stage of its first iteration: the compression line (182.78 MB/s)
is printed, the decompression line is not; RSS at the kill 7.32 GiB; journal: "A process of this unit has been killed
by the OOM killer". No crash without oom / oom_kill was seen (case C did not occur).

## Reading (preregistered interpretation)

Case A: aceapex reproducibly gets oom_kill under 7G (2/2) while aceapex_fast passes under the same limit (2/2) — the
dependence on the memory limit is confirmed. Its link to powturbo's crash stays a hypothesis until his platform and
command are known. Other aceapex profiles on enwik9 peak at 6.1-6.7 GiB, so under a 6G limit they would be killed too
(not measured beyond level 3 t1).
