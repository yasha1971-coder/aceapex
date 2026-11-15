#!/bin/bash
# TRAIN-1 driver — runs ON the self-deleting GCP L4 GPU VM (launched by the orchestrator
# over SSH). Same scheme as DUEL/MT-3: the cohort (q4k), the reference and the panvram
# SOURCE (git archive 01f0ce1) arrive by scp from ace-core — the VM's default service
# account has NO roles, so there is no bucket/gsutil and no self-delete here. The driver
# only builds panvram from source (code UNCHANGED), runs examples/train_small.py and writes
# ~/train1_out/{logs,results,STATUS}. The orchestrator scp's results back and deletes the VM
# with user creds. panvram is FROZEN: we install from a read-only source archive, never edit.
#
# Env the orchestrator may pass: TRAIN_SEEDS (default "default 1 2"), TRAIN_BATCH (64),
#   TRAIN_W (2048), TRAIN_STEPS (2000), TRAIN_HOLDOUT (50).
# Usage: bash train1_driver.sh <out_dir>   (cohort_q4k.tgz, t2t.fa.gz, panvram_src.tgz in ~)
set -uo pipefail
OUT="${1:?out_dir}"; mkdir -p "$OUT"/{logs,results,src}
export TRAIN1_STATUS="$OUT/STATUS"
S(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$OUT/logs/driver.log" "$OUT/STATUS" >/dev/null; echo "$*"; }
DIE(){ S "DIE: $*"; exit 1; }
need(){ [ -s "$1" ] || DIE "missing/empty: $1 ($2)"; local sz; sz=$(stat -c %s "$1"); [ "$sz" -ge "${3:-1}" ] || DIE "too small: $1 = $sz B (<$3)"; S "have $1 ($sz B)"; }

SEEDS="${TRAIN_SEEDS:-default 1 2}"
BATCH="${TRAIN_BATCH:-64}"; W="${TRAIN_W:-2048}"; STEPS="${TRAIN_STEPS:-2000}"; HOLDOUT="${TRAIN_HOLDOUT:-50}"

export DEBIAN_FRONTEND=noninteractive
# 1) GPU DRIVER: install-nvidia-driver=True provisions the driver on first boot; it can take
#    a few minutes. Poll nvidia-smi; DIE with a clear message if the GPU never appears (no
#    running without a GPU — this task's metric is bits/base on CUDA).
S "wait for NVIDIA driver (install-nvidia-driver=True runs at first boot)"
NVSMI=""
for i in $(seq 1 60); do
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then NVSMI=ok; break; fi
  sleep 10
done
[ "$NVSMI" = ok ] || DIE "nvidia-smi not ready after 10 min (DL image install-nvidia-driver). No GPU -> cannot run."
GPUINFO=$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -1)
S "GPU: $GPUINFO"
case "$GPUINFO" in *L4*) : ;; *) S "WARN: GPU is not an L4 ($GPUINFO) — bits/base is GPU-independent, tokens_per_s will differ";; esac

# 2) Python + torch(cuda). Deep Learning VM (common-cu123) ships python + CUDA toolkit (nvcc)
#    but not always torch; install a CUDA torch wheel if import fails, then HARD-verify cuda.
PY="$(command -v python3)"; S "python: $("$PY" --version 2>&1) at $PY"
ensure_torch(){ "$PY" -c "import torch" >/dev/null 2>&1 && return 0
  S "torch not present -> pip install torch (cuda wheel)"
  "$PY" -m pip -q install --upgrade pip >>"$OUT/logs/driver.log" 2>&1 || true
  "$PY" -m pip -q install torch >>"$OUT/logs/driver.log" 2>&1 \
    || "$PY" -m pip -q install torch --index-url https://download.pytorch.org/whl/cu121 >>"$OUT/logs/driver.log" 2>&1 \
    || DIE "torch install failed"; }
ensure_torch
"$PY" - <<'PY' 2>&1 | tee -a "$OUT/logs/driver.log" || DIE "torch cannot see CUDA on this VM (torch.cuda.is_available() is False)"
import torch, sys
ok = torch.cuda.is_available()
print("torch", torch.__version__, "cuda_build", torch.version.cuda, "is_available", ok,
      "device", (torch.cuda.get_device_name(0) if ok else "NONE"))
sys.exit(0 if ok else 1)
PY
S "HEALTH: torch.cuda OK on $GPUINFO"

# 3) CUDA toolkit for building panvram's pv_cuda.cu
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"; export CUDA_HOME
[ -x "$CUDA_HOME/bin/nvcc" ] && export PATH="$CUDA_HOME/bin:$PATH"
command -v nvcc >/dev/null 2>&1 && S "nvcc: $(nvcc --version | tail -1)" || S "WARN: nvcc not found at $CUDA_HOME/bin (panvram CUDA ext build may fail)"

# 3b) C/C++ compiler + ninja. The PyTorch DL image ships torch + CUDA toolkit but NO gcc/g++,
#     so the panvram extension cannot compile (first build dies at `x86_64-linux-gnu-gcc: No such
#     file or directory`). Install build-essential (passwordless sudo on DL images) + ninja.
# build-essential (gcc/g++) AND python3-dev (Python.h) are both absent on the DL image; the
# extension needs both (pv_core.cpp includes <Python.h> via torch/extension.h).
# The extension needs: gcc/g++ (build-essential), Python.h (python3-dev), and zstd.h + libzstd
# (libzstd-dev) — panvram's only external lib is zstd (csrc includes <zstd.h>, libraries=["zstd"]).
# All three are absent on the PyTorch DL image; install them in one apt transaction.
if ! { command -v gcc >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1 \
       && [ -e /usr/include/python3.10/Python.h ] && [ -e /usr/include/zstd.h ]; }; then
  S "install build-essential + python3-dev + libzstd-dev (absent on DL image)"
  sudo apt-get -qq update >>"$OUT/logs/driver.log" 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y build-essential python3-dev libzstd-dev >>"$OUT/logs/driver.log" 2>&1 || true
fi
command -v gcc >/dev/null 2>&1 || DIE "gcc still missing after apt (cannot build panvram extension)"
ls /usr/include/python3.10/Python.h >/dev/null 2>&1 || DIE "Python.h still missing after apt (python3-dev)"
ls /usr/include/zstd.h >/dev/null 2>&1 || DIE "zstd.h still missing after apt (libzstd-dev)"
"$PY" -m pip -q install ninja >>"$OUT/logs/driver.log" 2>&1 || true   # fast torch BuildExtension backend

# 4) Stage files (scp'd from ace-core) -> extract. Verify each before use.
cd ~
need cohort_q4k.tgz "cohort q4k archives" 5000000000
need t2t.fa.gz      "reference chm13v2.0 (t2t.fa) gz" 500000000
need panvram_src.tgz "panvram source (01f0ce1)" 100000
S "extract cohort"
mkdir -p "$OUT/cohort" && tar xzf cohort_q4k.tgz -C "$OUT/cohort"
CO=$(dirname "$(find "$OUT/cohort" -name '*.q4k.rr3' | head -1)")
[ -n "$CO" ] && ls "$CO"/*.q4k.rr3 >/dev/null 2>&1 || DIE "no *.q4k.rr3 after extract"
NQ=$(ls "$CO"/*.q4k.rr3 | wc -l); S "cohort at $CO ($NQ q4k archives)"
[ "$NQ" -ge 500 ] || S "WARN: only $NQ q4k archives (expected ~558)"
S "decompress reference"
gunzip -f t2t.fa.gz; REF="$HOME/t2t.fa"; need "$REF" "reference fasta" 2000000000
S "extract panvram source"
tar xzf panvram_src.tgz -C "$OUT/src"
[ -f "$OUT/src/examples/train_small.py" ] || DIE "examples/train_small.py not in source archive"
PVSHA="$(cat "$OUT/src/.panvram_sha" 2>/dev/null || echo unknown)"; S "panvram source sha (recorded by orchestrator): $PVSHA"

# 5) Build panvram from source with CUDA (code unchanged). --no-build-isolation ONLY: the extension
#    must build against THIS image's torch (cu129, matching nvcc 12.9). The old isolating fallback
#    (`pip install .`) pulled a fresh PyPI torch (2.14/cu130) -> CUDA 13.0 vs 12.9 mismatch, so it
#    is removed. Build deps (setuptools/wheel/torch/ninja) are already present in the image env.
S "pip install panvram (PANVRAM_CUDA=1, from source, --no-build-isolation against image torch cu129)"
( cd "$OUT/src" && PANVRAM_CUDA=1 "$PY" -m pip install --no-build-isolation . ) >>"$OUT/logs/driver.log" 2>&1 \
  || DIE "panvram build/install failed (see driver.log)"
"$PY" -c "import panvram; print('panvram', getattr(panvram,'__version__','?'))" 2>&1 | tee -a "$OUT/logs/driver.log" \
  || DIE "panvram import failed after install"
S "HEALTH: panvram imported (CUDA build)"

# 6) Runs: one per seed. train_small.py prints 2 JSON lines (cohort / reference_only) to stdout;
#    we tee each run to its own log and extract the JSON lines. OOM on the training batch ->
#    retry with a smaller batch and RECORD it (never change the task silently).
RUNALL="$OUT/results/train1_runs.jsonl"; : > "$RUNALL"
run_seed(){
  local seedlabel="$1" seedarg="$2" b="$BATCH" log try rc
  for b in "$BATCH" 32 16; do
    log="$OUT/logs/train1.seed-${seedlabel}.b${b}.log"
    S "RUN seed=$seedlabel batch=$b W=$W steps=$STEPS holdout=$HOLDOUT"
    ( cd "$OUT/src" && "$PY" examples/train_small.py \
        --cohort "$CO" --reference "$REF" --dataset q4k --device cuda \
        --holdout "$HOLDOUT" --steps "$STEPS" --W "$W" --batch "$b" $seedarg ) >"$log" 2>&1
    rc=$?
    if [ $rc -eq 0 ] && grep -q '"heldout_bits_per_base"' "$log"; then
      grep '^{' "$log" | while IFS= read -r line; do
        echo "$line" | "$PY" -c "import sys,json; d=json.load(sys.stdin); d['seed_label']='$seedlabel'; d['batch_used']=$b; print(json.dumps(d))"
      done >> "$RUNALL"
      S "OK seed=$seedlabel batch=$b: $(grep '^{' "$log" | "$PY" -c "import sys,json; [print(json.loads(l)['model'],json.loads(l)['heldout_bits_per_base']) for l in sys.stdin]" 2>/dev/null | tr '\n' ' ')"
      [ "$b" != "$BATCH" ] && S "NOTE seed=$seedlabel ran at batch=$b (< requested $BATCH) after OOM — recorded in logs/results"
      return 0
    fi
    if grep -qi "out of memory\|CUDA out of memory\|OutOfMemoryError" "$log"; then
      S "OOM seed=$seedlabel at batch=$b -> retry smaller"; continue
    fi
    S "FAIL seed=$seedlabel batch=$b rc=$rc (not OOM) — see $log"; return 1
  done
  S "FAIL seed=$seedlabel: OOM even at batch=16"; return 1
}

for sd in $SEEDS; do
  case "$sd" in default) run_seed default "" || true;; *) run_seed "$sd" "--seed $sd" || true;; esac
done

# 7) Summary: per-seed cohort vs reference_only delta in bits/base, and the prereg verdict
#    (>= 0.01 bit/base lower on holdout for cohort => effect; < 0.01 => no effect).
"$PY" - "$RUNALL" "$OUT/results/train1_summary.json" "$PVSHA" <<'PY' 2>&1 | tee -a "$OUT/logs/driver.log" || S "WARN summary build failed"
import sys, json
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by={}
for r in rows: by.setdefault(r['seed_label'],{})[r['model']]=r
seeds=[]
for sl,d in by.items():
    c=d.get('cohort'); ro=d.get('reference_only')
    e={'seed_label':sl}
    if c: e.update(cohort_bits=c['heldout_bits_per_base'], cohort_tok_s=c['tokens_per_s'], batch_used=c.get('batch_used'))
    if ro: e.update(reference_bits=ro['heldout_bits_per_base'], reference_tok_s=ro['tokens_per_s'])
    if c and ro:
        delta=round(ro['heldout_bits_per_base']-c['heldout_bits_per_base'],4)  # >0 => cohort better
        e['cohort_minus_ref_improvement_bits']=delta
        e['verdict']='effect' if delta>=0.01 else 'no effect'
    seeds.append(e)
deltas=[e['cohort_minus_ref_improvement_bits'] for e in seeds if 'cohort_minus_ref_improvement_bits' in e]
out={'panvram_sha':sys.argv[3],'seeds':seeds,
     'mean_improvement_bits':round(sum(deltas)/len(deltas),4) if deltas else None,
     'prereg_rule':'cohort >= 0.01 bit/base lower on holdout => effect; < 0.01 => no effect'}
json.dump(out,open(sys.argv[2],'w'),indent=2)
print(json.dumps(out))
PY

S "ALL DONE"
