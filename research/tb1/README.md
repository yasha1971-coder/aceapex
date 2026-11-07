# TB-1 — no aceapex / aceapex-fast in TurboBench windows-x86_64 (v2026.11.06.165)

Release asset `turbobench-windows-x86_64.zip` (sha256 eab3eeb8…80b2c17), `turbobench.exe` 175d2441…db053: `-l2` (wine) lists
no aceapex codec; the strings `aceapex`, `aceapex-fast` and the FAST group line are in the exe only as names of the plugin
table (compiled with `_ACEAPEX 0`).

Cause: TurboBench's makefile, v2026.11.06.165 lines 186 and 198, wraps the aceapex block (the only place that adds
`-D_ACEAPEX` and `aceapex_api.o`) in

    ifneq ($(OS), Windows)  # not compiling for windows in CI.
    ...
    endif

so on Windows neither aceapex nor aceapex-fast is built. Not a submodule, wildcard or compile error, and not our code.

Our CI (branch tb-1, run 42337527722): windows-latest, MSYS2 UCRT64 (gcc.exe Rev6 16.2.0, clang 23.1.5), tag v165
(2cc8b4f, aceapex submodule b67c858), its release command `make STATIC=1 PHAZ=0`:
- `as-is/`: make rc 0; `-l2` has no aceapex (the step is red only because a `grep aceapex make.log` found nothing).
- `no-guard/`: the same with only those two lines removed (`makefile.diff`): make rc 0; aceapex_api.cpp compiled by
  `g++ -O3 -std=c++17 -march=haswell -DXXH_INLINE_ALL ...`; `-l2` lists `aceapex v2.6.1 MT`, `aceapex fast v2.6.1 MT`;
  silesia.tar (sha256 a667bac8…) `-C4 -v2`: `-eaceapex,1` .. `-eaceapex,4` and `-eaceapex-fast,1` each rc 0 (the
  printed rows in `smoke.txt` repeat the merged table's first aceapex line, the rc per run is what counts).

Proposal for powturbo: drop the Windows guard around the aceapex block (keep the other `ifneq ($(OS), Windows)` at
line 298, which belongs to another codec).
