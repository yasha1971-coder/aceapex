# TRAIN-1 kit — panvram cohort-vs-reference on a self-deleting L4 GPU VM

First real panvram number: does a model trained on the 558-assembly cohort (q4k, via panvram)
beat a model trained on the reference `chm13v2.0.fa` alone, on 50 held-out assemblies, in
bits/base? Prereg: `~/yasha-context/ACEAPEX/train1/PREREG_TRAIN1.md` (1e9505b). Decision rule:
cohort ≥ 0.01 bit/base lower on holdout → effect; < 0.01 → no effect.

panvram is FROZEN: the kit builds it from a pinned source archive (`git archive 01f0ce1`) and
runs `examples/train_small.py` unchanged. No edit to the panvram repo.

## Files (`bench/train1/kit/`)
- `train1_gcloud.sh` — orchestrator, runs on ace-core with user creds (yasha1971@gmail.com,
  project aceapex-bench). Creates the VM, scp's data+source+driver, polls, fetches, DELETES the
  VM in a signal-safe trap, copies logs to yasha-context. `stage` (optional) / `run`.
- `train1_driver.sh` — runs ON the VM. Waits for the NVIDIA driver, verifies `torch.cuda`,
  builds panvram (PANVRAM_CUDA=1), runs train_small.py for 3 seeds, writes JSON + summary.

## Operator: one tmux line on ace-core
```
tmux new -d -s train1 'bash ~/pubrepo/bench/train1/kit/train1_gcloud.sh run ~/train1_work 2>&1 | tee ~/train1_work/run.log'
```
The agent does NOT create the VM (safety interlock); the operator runs the line above.

## Config
- VM: L4 (G2). Machine types tried in order `g2-standard-16 g2-standard-8` (16 → 64 GB RAM: the
  reference FASTA is tokenised in CPU RAM). Zones swept across europe-west4 / us-central1 /
  us-west1 / us-west4 / europe-west1 / asia-southeast1 (quota NVIDIA_L4_GPUS=1 per region,
  GPUS_ALL_REGIONS=1 → one L4 at a time).
- Image: Deep Learning VM `common-cu123` (`deeplearning-platform-release`) +
  `install-nvidia-driver=True`, `--maintenance-policy TERMINATE` (GPU requirement).
- Self-delete: `--max-run-duration 4h --instance-termination-action DELETE` (platform backstop)
  PLUS the orchestrator trap deletes the VM with user creds on any exit (EXIT/INT/TERM/HUP),
  idempotent, then prints empty instances/disks.
- Data: reuses the DUEL bucket `gs://aceapex-bench-duel1` (cohort_q4k.tgz, t2t.fa.gz already
  there); staged to the VM by scp. panvram_src.tgz is always rebuilt fresh from 01f0ce1.
- Run (per seed `default`, `1`, `2`):
  `python examples/train_small.py --cohort <q4k dir> --reference t2t.fa --dataset q4k --device cuda --holdout 50 --steps 2000 --W 2048 --batch 64`
  On CUDA OOM the batch drops 64→32→16 and the used batch is recorded in logs + results
  (the task is not changed silently). bits/base is GPU-independent; L4 tokens_per_s is lower
  than A100 — reported honestly.

## Where the output lands (ace-core)
- `~/train1_work/gcloud.log` — orchestration + GPU + SUMMARY.
- `~/train1_work/train1_out/logs/train1.seed-*.log` — raw run logs (JSON lines per model).
- `~/train1_work/train1_out/results/train1_runs.jsonl` — one JSON per (seed, model).
- `~/train1_work/train1_out/results/train1_summary.json` — per-seed delta + prereg verdict.
- Copied to `~/yasha-context/ACEAPEX/train1/logs/` (prereg requires the log there).

## Health check (what to grep in gcloud.log / STATUS)
A healthy run shows, in order:
- `GPU: NVIDIA L4, 24564 MiB, …`
- `HEALTH: torch.cuda OK on NVIDIA L4 …`
- `HEALTH: panvram imported (CUDA build)`
- `OK seed=default batch=64: cohort <bits> reference_only <bits>` (then seed 1, seed 2)
- `ALL DONE`
Any `DIE:` line (no GPU, torch can't see CUDA, panvram build failed, missing/too-small data)
stops the run with a readable reason. The VM is deleted either way; the final
`instances:` / `disks:` lists in gcloud.log must be empty.
