# CRASH-1 — TurboBench #65 report: "aceapex is crashing under TurboBench on large files (e.g. silesia.tar, enwik9)"

Report: powturbo, 2026-11-06 18:12 UTC. Exact command, release, platform, level, t# and signal: not given.
Scope: `aceapex` (levels 1-4, the default profile). `aceapex_fast` is reported working.

## Binaries (official TurboBench release v2026.11.06.164, submodule aceapex = b67c858b3b18d4d57aee1aa7bcaf0cf2c773d050)

| asset | sha256 | aceapex in `-l2` |
|---|---|---|
| turbobench-linux-x86_64.tar.gz | 984b07abd5bfe1e0c63bbf005f9ae30014ab30d6b4e68f89328d53e5de91fda4 (binary d0bcfc9d…e1da1d8) | yes, v2.6.1 |
| turbobench-linux-aarch64.tar.gz | 7976155ec01be5c59c66859a9ebeee7cd1a14b59cf215412278c4529739b0fd2 | yes |
| turbobench-linux-riscv64.tar.gz | 59540205681abcc5881e6d05ebb9610ffa9b5f17c35fd00d138b822dd496cd69 | yes |
| turbobench-windows-x86_64.zip | 4d5b74ab81dac3b704ab7e499ca0f2d5152dcf62518db3c320cf32b6a608b73d | no (not built in) |
| macos-aarch64 | not tested (no macOS host) | — |

Inputs: silesia.tar 211 947 520 B sha256 a667bac80089b3d04d5496772149e632f0758974b0579d743cd8d6e5e0d63eb2 (corpus-collection);
enwik9 1 000 000 000 B sha256 159b85351e5f76e60cbe32e04c677847a9ecba3adc79addab6f4c6c7aa3744bc.
Host: ace-core, AMD EPYC 4344P, Ubuntu 22.04. Every run in a clean directory (no old .tbb).

## Results (`logs/`)

| binary | command | runs | result |
|---|---|---|---|
| linux-x86_64 | `turbobench silesia.tar -C4 -v2 -eaceapex,1,2,3,4` (no t#) | 2 | rc 0, all 4 levels, -C4 check passed |
| linux-x86_64 | `turbobench enwik9 -C4 -v2 -eaceapex,1,2,3,4` (no t#) | 2 | rc 0 |
| linux-x86_64 | same with `aceapex,1:t2,2:t2,3:t2,4:t2`, silesia / enwik9 | 2 + 2 | rc 0 |
| linux-x86_64 | same with `:t4`, silesia / enwik9 | 2 + 2 | rc 0 |
| linux-aarch64 (qemu-aarch64 6.2) | silesia, aceapex 1-4, no t# | 1 | rc 0 |
| linux-riscv64 (qemu-riscv64 6.2) | 20 MB slice, `-ememcpy` / `-eaceapex_fast,1` / `-eaceapex,1` | 1 each | memcpy rc 0; both aceapex codecs SIGILL at an RVV instruction (opcode 0x57, `cd817057` in `aceapex_compress`) — the binary uses RVV, qemu 6.2 has no RVV 1.0: an emulator limit, riscv64 not testable here |

Thread-stack condition of macOS (512 KiB secondary-thread stacks), x86 binary, `ulimit -S -s 512` (TurboBench raises
its own main stack): aceapex t2, aceapex no t#, aceapex_fast t2 — rc 0. With a HARD 512 KiB limit TurboBench itself
crashes (SIGSEGV) even with `-ememcpy` only (`setrlimit failed ... 20971520`): not an aceapex result.

Library at b67c858 under ASan+UBSan (`tbshape.cpp`: the calls exactly as plugin.cc makes them — compress into
1.3 n + 10 MB, decompress into exactly n — plus short destinations zs-1, zs/2, 64 and n-1, n/2):
silesia t1 and t4, enwik9 t1, levels 1-4: 12/12 round trips byte-exact, 60/60 short destinations return -1, 0 sanitizer
reports. `aceapex_compress_bound` (1.125 n + 1024) < TurboBench's buffer (1.3 n + 10 MB).

## Status

Not reproduced (x86_64 12/12, aarch64 1/1, ASan 0 reports). An ASan build of the whole TurboBench was NOT done;
a separate ASan+UBSan harness of the library (`tbshape.cpp`, above) was. Steps 3-4 (ASan TurboBench build, bisect
v2.6.1..b67c858) need a reproduction first. No code change, no API/ABI change, no release. Request to powturbo: `request-to-powturbo.md`
(draft, not sent).
