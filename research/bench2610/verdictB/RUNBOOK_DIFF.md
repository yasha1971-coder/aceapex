# RUN.md (A2/S5, 6c576b6) against how the 2026-10-08 verdict run was actually performed - differences, not corrections

The run used the B runbook at 0ace54d (its copy is hash-bound in plan.json). A2/S5 rewrote RUN.md after the run.
Comparison of the A2 text with the actual steps (`make_root.py`, `spec_hprc4.json`, shell history of 2026-10-07):

| RUN.md (A2/S5) | what was done | status |
|---|---|---|
| `prepare ... --windows 1,1024,8192,65536` (minimal list; the full sweep is optional and "freeze that decision before use") | prepare without `--windows`: the full sweep W = 1, 2, ..., 65536 (17 points x 10 000). The choice is recorded in `prepared/prepared.json` (windows_bytes) but was not frozen in a separate document before the run | different (allowed by the text; decision not pre-frozen) |
| environment block: `PYTHON` with jsonschema 4.26.0, `git status --short`, `harness_identity` | hw-apex venv (`.wk/hwvenv`, jsonschema 4.26.0), clean worktree at 0ace54d; harness identity recorded by the job itself (commit 0ace54d, tree 06fd3c5f) | same |
| recipe `freeze-runbook` (copy tracked RUN.md into INPUT_ROOT, refuse a changed copy) | `shutil.copy` of the tracked RUN.md at 0ace54d into INPUT_ROOT; same bytes; the job checked its hash via plan.json. The retained copy now differs from the A2 RUN.md: a new run needs a new input directory (as the A2 text says) | same bytes; new text changes future runs |
| recipe `validate-inputs` (INPUT_HASHES_PASS before the run) | not run as a separate step; the `run` command performed the same load_plan + checked_file of every reference before timing | not run explicitly |
| `check-refrel3` / `check-bgzf-default` / `check-bgzf-matched` on the synthetic archive before the official run | not run on ace-core; the same checks ran in CI (B workflows, B_NATIVE_FULL_PASS) | not run locally |
| build table: LZ4 via `build_lz4_native.sh` (A1 v2 fix), zstd-seekable via `codecs/zstd_seekable.sh` | LZ4 built by `research/bench2610/hw_s2/build_native_rest.sh` (the same cc line, version read from the MAJOR/MINOR/RELEASE macros, before A1 v2 existed); zstd shim built by the gcc line of `codecs/zstd_seekable.sh` against the v1.5.7 tree (not through the codec script's harness entry). Receipts record the actual commands, commit and library SHA | equivalent commands, not the named entrypoints |
| "Never substitute toy sources" | the official run used the HPRC sources (URL + .fa.gz SHA of MANIFEST.tsv). A separate method check ran the job on the 4 clean-room fixtures (`rehearsal/`, run_id rehearsal-small, `file://` URLs); its results.json carries kind "measured" because the job has no rehearsal mode - it must not be read as official evidence | official run compliant; rehearsal labelled |
| AGC: geometry evidence required, else FAILED | `agc/GEOMETRY_MISSING.json` + note; the job reports "AGC canonical granule evidence is missing or not archive-bound" | same |
| plan: both refrel3 Q, both BGZF configurations, >= 4 foreign families, 3 + 9, seed 20261003 | same (11 variants; OZSEG 4 variants) | same |
| section 4 run command and `window-law-B` output name; verify + `sha256sum -c` | same | same |

No file of the run or of RUN.md was changed for this comparison.
