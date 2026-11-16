#!/bin/bash
# TRAIN-2 driver — runs ON the self-deleting GCP L4 GPU VM (launched by the orchestrator).
# Same provisioning as train1_driver.sh (GPU wait, torch-cuda verify, build-essential +
# python3-dev + libzstd-dev, build panvram from the FROZEN source 01f0ce1 UNCHANGED). Then,
# per seed: run train2_eval.py (trains cohort + reference_only, SAVES weights, evaluates on
# three held-out sets: random / HLA+KIR+SegDup / SV-insertion). Finally a prereg-rule summary.
# Expects in ~: cohort_q4k.tgz, t2t.fa.gz, panvram_src.tgz, train2_eval.py, train2_eval_windows.json
# Usage: bash train2_driver.sh <out_dir>
set -uo pipefail
OUT="${1:?out_dir}"; mkdir -p "$OUT"/{logs,results,src,weights}
export TRAIN2_STATUS="$OUT/STATUS"
S(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$OUT/logs/driver.log" "$OUT/STATUS" >/dev/null; echo "$*"; }
DIE(){ S "DIE: $*"; exit 1; }
need(){ [ -s "$1" ] || DIE "missing/empty: $1 ($2)"; local sz; sz=$(stat -c %s "$1"); [ "$sz" -ge "${3:-1}" ] || DIE "too small: $1 = $sz B (<$3)"; S "have $1 ($sz B)"; }

SEEDS="${TRAIN_SEEDS:-default 1 2}"
BATCH="${TRAIN_BATCH:-64}"; W="${TRAIN_W:-2048}"; STEPS="${TRAIN_STEPS:-2000}"; HOLDOUT="${TRAIN_HOLDOUT:-50}"
export DEBIAN_FRONTEND=noninteractive

S "wait for NVIDIA driver"
NVSMI=""
for i in $(seq 1 60); do command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1 && { NVSMI=ok; break; }; sleep 10; done
[ "$NVSMI" = ok ] || DIE "nvidia-smi not ready after 10 min"
S "GPU: $(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -1)"

PY="$(command -v python3)"; S "python: $("$PY" --version 2>&1)"
"$PY" -c "import torch" >/dev/null 2>&1 || { "$PY" -m pip -q install torch >>"$OUT/logs/driver.log" 2>&1 || "$PY" -m pip -q install torch --index-url https://download.pytorch.org/whl/cu121 >>"$OUT/logs/driver.log" 2>&1 || DIE "torch install failed"; }
"$PY" - <<'PY' 2>&1 | tee -a "$OUT/logs/driver.log" || DIE "torch cannot see CUDA"
import torch,sys
ok=torch.cuda.is_available(); print("torch",torch.__version__,"cuda",torch.version.cuda,"avail",ok,"dev",(torch.cuda.get_device_name(0) if ok else "NONE")); sys.exit(0 if ok else 1)
PY
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"; export CUDA_HOME; [ -x "$CUDA_HOME/bin/nvcc" ] && export PATH="$CUDA_HOME/bin:$PATH"
if ! { command -v gcc >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1 && [ -e /usr/include/python3.10/Python.h ] && [ -e /usr/include/zstd.h ]; }; then
  S "install build-essential + python3-dev + libzstd-dev"
  sudo apt-get -qq update >>"$OUT/logs/driver.log" 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y build-essential python3-dev libzstd-dev >>"$OUT/logs/driver.log" 2>&1 || true
fi
command -v gcc >/dev/null 2>&1 || DIE "gcc missing"; ls /usr/include/zstd.h >/dev/null 2>&1 || DIE "zstd.h missing"
"$PY" -m pip -q install ninja >>"$OUT/logs/driver.log" 2>&1 || true

cd ~
need cohort_q4k.tgz "cohort q4k" 5000000000
need t2t.fa.gz "reference" 500000000
need panvram_src.tgz "panvram source" 100000
need train2_eval.py "train2 eval" 1000
need train2_eval_windows.json "eval windows" 1000
mkdir -p "$OUT/cohort" && tar xzf cohort_q4k.tgz -C "$OUT/cohort"
CO=$(dirname "$(find "$OUT/cohort" -name '*.q4k.rr3' | head -1)")
[ -n "$CO" ] && ls "$CO"/*.q4k.rr3 >/dev/null 2>&1 || DIE "no q4k after extract"
S "cohort at $CO ($(ls "$CO"/*.q4k.rr3 | wc -l) q4k)"
gunzip -f t2t.fa.gz; REF="$HOME/t2t.fa"; need "$REF" "reference fasta" 2000000000
tar xzf panvram_src.tgz -C "$OUT/src"
[ -f "$OUT/src/examples/train_small.py" ] || DIE "train_small.py not in source"
PVSHA="$(cat "$OUT/src/.panvram_sha" 2>/dev/null || echo unknown)"; S "panvram sha: $PVSHA"
S "build panvram (PANVRAM_CUDA=1, --no-build-isolation)"
( cd "$OUT/src" && PANVRAM_CUDA=1 "$PY" -m pip install --no-build-isolation . ) >>"$OUT/logs/driver.log" 2>&1 || DIE "panvram build failed"
"$PY" -c "import panvram;print('panvram',getattr(panvram,'__version__','?'))" 2>&1 | tee -a "$OUT/logs/driver.log" || DIE "panvram import failed"

run_seed(){
  local label="$1" seed="$2" b rc log
  for b in "$BATCH" 32 16; do
    log="$OUT/logs/train2.seed-${label}.b${b}.log"
    S "RUN seed=$label ($seed) batch=$b steps=$STEPS W=$W holdout=$HOLDOUT"
    "$PY" ~/train2_eval.py --cohort "$CO" --reference "$REF" --device cuda \
       --holdout "$HOLDOUT" --steps "$STEPS" --batch "$b" --W "$W" \
       --seed "$seed" --seed-label "$label" --eval-windows ~/train2_eval_windows.json \
       --src-examples "$OUT/src/examples" --out "$OUT/results" >"$log" 2>&1
    rc=$?
    if [ $rc -eq 0 ] && [ -s "$OUT/results/train2.seed-${label}.json" ]; then
      [ "$b" != "$BATCH" ] && S "NOTE seed=$label ran batch=$b after OOM"
      S "OK seed=$label batch=$b (weights in results/weights)"
      return 0
    fi
    if grep -qi "out of memory\|OutOfMemoryError" "$log"; then S "OOM seed=$label b=$b -> smaller"; continue; fi
    S "FAIL seed=$label b=$b rc=$rc (not OOM) — see $log"; return 1
  done
  S "FAIL seed=$label: OOM even at 16"; return 1
}
for sd in $SEEDS; do case "$sd" in default) run_seed default 20261115 || true;; *) run_seed "$sd" "$sd" || true;; esac; done

# prereg-rule summary: mean over seeds of (reference_only - cohort) per set.
"$PY" - "$OUT/results" "$OUT/results/train2_summary.json" "$PVSHA" <<'PY' 2>&1 | tee -a "$OUT/logs/driver.log" || S "WARN summary failed"
import sys,json,glob,os
res=sys.argv[1]
rows=[json.load(open(f)) for f in sorted(glob.glob(os.path.join(res,"train2.seed-*.json")))]
sets=["random","hla_kir_segdup","sv_insertion"]
per_seed=[]; agg={s:[] for s in sets}
for r in rows:
    c=r["models"].get("cohort",{}); ro=r["models"].get("reference_only",{})
    e={"seed_label":r["seed_label"]}
    for s in sets:
        if c.get(s) is not None and ro.get(s) is not None:
            d=round(ro[s]-c[s],4); e[s+"_ref_minus_cohort"]=d; e[s+"_cohort"]=c[s]; e[s+"_ref"]=ro[s]; agg[s].append(d)
    per_seed.append(e)
def verdict(m):
    if m is None: return "n/a"
    if m>=0.05: return "effect"
    if m>=0.01: return "weak/inconclusive"
    return "no effect"
means={s:(round(sum(agg[s])/len(agg[s]),4) if agg[s] else None) for s in sets}
confirmed = (means["hla_kir_segdup"] is not None and means["hla_kir_segdup"]>=0.05
             and means["sv_insertion"] is not None and means["sv_insertion"]>=0.05
             and means["random"] is not None and means["random"]<0.01)
out={"panvram_sha":sys.argv[3],"per_seed":per_seed,
     "mean_ref_minus_cohort":means,"verdict_per_set":{s:verdict(means[s]) for s in sets},
     "hypothesis_confirmed":bool(confirmed),
     "prereg_rule":">=0.05 effect; 0.01-0.05 weak; <0.01 none; hypothesis needs b AND c >=0.05 AND random <0.01"}
json.dump(out,open(sys.argv[2],"w"),indent=2); print(json.dumps(out))
PY
S "ALL DONE"
