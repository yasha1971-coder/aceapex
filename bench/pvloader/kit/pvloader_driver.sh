#!/bin/bash
# PV-LOADER driver — runs ON the self-deleting GCP L4 GPU VM (launched by the orchestrator).
# Provisioning identical to train2_driver.sh (GPU wait, torch-cuda verify, build-essential +
# python3-dev + libzstd-dev, build panvram from FROZEN source 01f0ce1 UNCHANGED). Then ONE
# session runs the GPU stages: pvloader_s1_panvram.py (panvram win/s, on the 6 baseline
# assemblies AND all 558) + pvloader_s2.py (synthetic compute ceiling x1/x8/x64). NO S4 here —
# S4 runs only if the S3 prediction shows >=10% GPU idle.
# Expects in ~: cohort_q4k.tgz, t2t.fa.gz, panvram_src.tgz, pvloader_lib.py,
#               pvloader_s1_panvram.py, pvloader_s2.py
# Usage: bash pvloader_driver.sh <out_dir>
set -uo pipefail
OUT="${1:?out_dir}"; mkdir -p "$OUT"/{logs,results,src}
export PVL_STATUS="$OUT/STATUS"
S(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$OUT/logs/driver.log" "$OUT/STATUS" >/dev/null; echo "$*"; }
DIE(){ S "DIE: $*"; exit 1; }
need(){ [ -s "$1" ] || DIE "missing/empty: $1 ($2)"; local sz; sz=$(stat -c %s "$1"); [ "$sz" -ge "${3:-1}" ] || DIE "too small: $1 = $sz B (<$3)"; S "have $1 ($sz B)"; }
export DEBIAN_FRONTEND=noninteractive

S "wait for NVIDIA driver"
NVSMI=""
for i in $(seq 1 60); do command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1 && { NVSMI=ok; break; }; sleep 10; done
[ "$NVSMI" = ok ] || DIE "nvidia-smi not ready after 10 min"
S "GPU: $(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -1)"
PY="$(command -v python3)"; S "python: $("$PY" --version 2>&1)"
"$PY" -c "import torch" >/dev/null 2>&1 || { "$PY" -m pip -q install torch >>"$OUT/logs/driver.log" 2>&1 || "$PY" -m pip -q install torch --index-url https://download.pytorch.org/whl/cu121 >>"$OUT/logs/driver.log" 2>&1 || DIE "torch install failed"; }
"$PY" - <<'PY' 2>&1 | tee -a "$OUT/logs/driver.log" || DIE "torch cannot see CUDA"
import torch,sys; ok=torch.cuda.is_available(); print("torch",torch.__version__,"cuda",torch.version.cuda,"avail",ok,"dev",(torch.cuda.get_device_name(0) if ok else "NONE")); sys.exit(0 if ok else 1)
PY
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"; export CUDA_HOME; [ -x "$CUDA_HOME/bin/nvcc" ] && export PATH="$CUDA_HOME/bin:$PATH"
if ! { command -v gcc >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1 && [ -e /usr/include/python3.10/Python.h ] && [ -e /usr/include/zstd.h ]; }; then
  S "install build-essential + python3-dev + libzstd-dev"
  sudo apt-get -qq update >>"$OUT/logs/driver.log" 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y build-essential python3-dev libzstd-dev >>"$OUT/logs/driver.log" 2>&1 || true
fi
command -v gcc >/dev/null 2>&1 || DIE "gcc missing"; ls /usr/include/zstd.h >/dev/null 2>&1 || DIE "zstd.h missing"
"$PY" -m pip -q install ninja xxhash >>"$OUT/logs/driver.log" 2>&1 || true

cd ~
need cohort_q4k.tgz "cohort q4k" 5000000000
need t2t.fa.gz "reference" 500000000
need panvram_src.tgz "panvram source" 100000
need pvloader_s1_panvram.py "s1-panvram" 500
need pvloader_s2.py "s2" 500
need pvloader_lib.py "lib" 100
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
cp ~/pvloader_lib.py "$OUT/" 2>/dev/null || true

# same 6 baseline assemblies as the CPU S1-base (apples-to-apples with pysam/memmap)
A6="r2_HG00097_hap1_hprc_r2_v1.0.1,r2_HG00097_hap2_hprc_r2_v1.0.1,r2_HG00438_mat_hprc_r2_v1.0.1,r2_HG00438_pat_hprc_r2_v1.0.1,r2_HG02630_mat_hprc_r2_v1.0.1,r2_HG02630_pat_hprc_r2_v1.0.1"

S "S1-panvram (6 baseline assemblies)"
( cd ~ && "$PY" pvloader_s1_panvram.py --cohort "$CO" --reference "$REF" --assemblies "$A6" \
    --W 2048 --batch 64 --n 10000 --repeats 5 --seed 20261115 --out "$OUT/results/s1_panvram_n6.json" ) >>"$OUT/logs/driver.log" 2>&1 \
  && S "OK S1-panvram n6: $(grep -o 'sample.*' "$OUT/results/s1_panvram_n6.json" | head -1)" || S "FAIL S1-panvram n6"

S "S1-panvram (all 558 resident)"
( cd ~ && "$PY" pvloader_s1_panvram.py --cohort "$CO" --reference "$REF" \
    --W 2048 --batch 64 --n 10000 --repeats 5 --seed 20261115 --out "$OUT/results/s1_panvram_all.json" ) >>"$OUT/logs/driver.log" 2>&1 \
  && S "OK S1-panvram all558" || S "FAIL S1-panvram all558 (VRAM? recorded)"

S "S2 synthetic ceiling (x1/x8/x64)"
( cd ~ && "$PY" pvloader_s2.py --src-examples "$OUT/src/examples" --W 2048 --batch 64 \
    --steps 50 --warmup 10 --out "$OUT/results/s2.json" ) >>"$OUT/logs/driver.log" 2>&1 \
  && S "OK S2: $(cat "$OUT/results/s2.json" | tr -d '\n' | head -c 400)" || S "FAIL S2"

S "ALL DONE (S4 NOT run here — only if S3 prediction shows >=10% idle)"
