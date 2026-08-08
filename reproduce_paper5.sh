#!/bin/bash
# reproduce_paper5.sh — reproduce the min_match_len data-dependent throughput lever (Paper 4/5).
# Reviewer: clone repo, obtain data by md5 (see DATA.md), run this. Judge = bit-perfect FNV.
#
# BASELINE NOTE: repo ships Paper-4 BASE threshold (6/8/10/12). This script sweeps FROM base
# to tuned (12/16/24/32) and beyond, matching Paper 4 Table III/IV (base -> tuned lever).
#
# Paper 4 claim: raising min_match by distance class (6/8/10/12 -> 12/16/24/32) improves BOTH
# ratio AND decode throughput on all tested data. Optimum = 12/16/24/32; pushing to 16/24/32/48
# raises throughput but lowers FASTQ ratio (3.97->3.93), so tuned is the universal win.
#
# Expected (H100, bs=16384, all bit-perfect):
#   FASTQ: base 3.90 / tuned 3.97 ratio; base 142.6 / tuned 178.6 GB/s
#   enwik9: base 2.64 / tuned 2.77 ratio; throughput +78%

set -uo pipefail
DIETGPU=${DIETGPU:-/workspace/dietgpu}
ZSTD_INC=${ZSTD_INC:-/workspace/lzbench-pr/lz/zstd/lib}
FASTQ=${FASTQ:-/workspace/data/NA12878_REAL.fastq}
ENWIK9=${ENWIK9:-/workspace/data/enwik9}
SILESIA=${SILESIA:-/workspace/data/silesia.tar}

export ACEAPEX_BS=16384
export LD_LIBRARY_PATH=$DIETGPU/build/lib:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}

echo "=== DEPENDENCIES ==="
apt-get update >/dev/null 2>&1
apt-get install -y libgoogle-glog-dev libgflags-dev libgoogle-glog0v5 libgflags2.2 >/dev/null 2>&1

echo "=== BUILD GPU decoder (e2e_dense) ==="
nvcc -O3 -arch=sm_90 -I$DIETGPU -I. -Isrc -o e2e_dense dense.cu \
    -L$DIETGPU/build/lib -lgpu_ans -ldietgpu_utils -lpthread \
    || { echo "decoder build failed"; exit 1; }
echo "decoder built"

build_encoder () {
  local A=$1 B=$2 C=$3 D=$4 OUT=$5
  cp aceapex_depth.cpp /tmp/_p5.cpp
  python3 - "$A" "$B" "$C" "$D" << 'PYEOF'
import sys
a,b,c,d = sys.argv[1:5]
f='/tmp/_p5.cpp'; s=open(f).read()
s=s.replace('if (dist < 128)     return 6;',  f'if (dist < 128)     return {a};')
s=s.replace('if (dist < 16384)   return 8;',  f'if (dist < 16384)   return {b};')
s=s.replace('if (dist < 2097152) return 10;', f'if (dist < 2097152) return {c};')
s=s.replace('    return 12;\n}', f'    return {d};\n}}')
open(f,'w').write(s)
PYEOF
  g++ -O3 -march=native -funroll-loops -std=c++17 -Isrc -I$ZSTD_INC -o "$OUT" /tmp/_p5.cpp \
      -lpthread /usr/lib/x86_64-linux-gnu/libzstd.so.1 2>/dev/null
}

run_one () {
  local SRC="$1" ENC="$2" LABEL="$3"
  ./$ENC c --in "$SRC" --out /tmp/p5.aet --threads 8 >/tmp/enc.log 2>&1
  local RATIO=$(grep -i "Ratio" /tmp/enc.log | head -1 | grep -oE '[0-9.]+x' | head -1)
  ./$ENC d --in /tmp/p5.aet --out /tmp/p5_dec >/dev/null 2>&1
  local OUT=$(./e2e_dense streams.bin "$SRC" 32 2>&1)
  local GBS=$(echo "$OUT" | grep -oE '[0-9.]+ GB/s' | tail -1)
  local FNV=$(echo "$OUT" | grep -iE "MATCHES|DIFFERS" | head -1)
  printf "  %-8s ratio %-9s %-12s %s\n" "$LABEL" "$RATIO" "$GBS" "$FNV"
}

echo ""
echo "=== BUILD ENCODERS (base -> tuned -> aggressive) ==="
build_encoder 6  8  10 12  ad_base
build_encoder 12 16 24 32  ad_tuned
build_encoder 16 24 32 48  ad_aggr
echo "encoders built"

for DS in "FASTQ:$FASTQ" "enwik9:$ENWIK9" "silesia:$SILESIA"; do
  NAME="${DS%%:*}"; PATH_="${DS#*:}"
  [ -f "$PATH_" ] || { echo "SKIP $NAME (not found: $PATH_)"; continue; }
  echo ""
  echo "=== $NAME ==="
  run_one "$PATH_" ad_base  "base"
  run_one "$PATH_" ad_tuned "tuned"
  run_one "$PATH_" ad_aggr  "aggr"
done

echo ""
echo "=== DONE. Paper 4/5 lever: tuned (12/16/24/32) beats base (6/8/10/12) ==="
echo "  ratio AND throughput both rise base->tuned on all data (Paper 4 Table III/IV)."
echo "  aggr (16/24/32/48) raises throughput more but can lower FASTQ ratio (3.97->3.93)."
echo "  tuned = universal win. All rows must show MATCHES OK (bit-perfect)."
