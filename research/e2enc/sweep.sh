#!/bin/bash
# E2-ENC sweep after S5 (Yakiv 10.11): one run per point on silesia, pinned core, load1 < 0.5.
#   A) levels 12 and 13: bucket width 8/16/24/32 x inserts edges/all (budget = width)
#   B) levels 15-18: LAMBDA 0.25 / 0.5 / 1.0 byte per token (S5 has epsilon)
# Variants are built from a patched copy of the branch's sources (macros only in the copy, never committed).
# Output: <W>/res/sweep.tsv (point, level, ratio %, comp MB/s, dec MB/s, status). Progress in <W>/STATUS.
set -euo pipefail
W=/home/aeterna/pubrepo/.wk/e2work; SRC=/home/aeterna/pubrepo/.wk/e2enc/src; F=/tmp/hwref/corpus/silesia.tar; CPU=2
V=$W/var; mkdir -p "$V/bin"; rm -rf "$V/src"; cp -r "$SRC" "$V/src"
python3 - "$V/src/ax_fast_enc.h" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
def rep(a, b):
    global s
    assert s.count(a) == 1, a[:60]; s = s.replace(a, b)
rep("    static const int BUDGET[3] = {DEPTH_GREEDY, DEPTH_GREEDY, 32};",
    "    static const int BUDGET[3] = {V_BW12, V_BW13, 32};")
rep("    static const uint32_t BWL[3] = {8, 8, 32};", "    static const uint32_t BWL[3] = {V_BW12, V_BW13, 32};")
rep("p.all_ins = level == 4;", "p.all_ins = level == 4 || (level == 2 && V_ALL12) || (level == 3 && V_ALL13);")
rep("const uint64_t K = 256, TOK = 4 * K + 1;", "const uint64_t K = 256, TOK = 4 * K + V_LAM;")
open(p, "w").write(s)
PY
quiet() { until awk "BEGIN{exit !($(cut -d' ' -f1 /proc/loadavg)<0.5)}"; do sleep 10; done; }
build() { local name=$1; shift; [ -x "$V/bin/$name" ] && return 0
  g++ -std=c++17 -O3 -march=native -funroll-loops -DACEAPEX_CLI "$@" -I"$V/src" -c -o "$V/$name.o" "$V/src/aceapex_api.cpp"
  g++ -o "$V/bin/$name" "$V/$name.o" -lpthread -lzstd; }
T=$W/res/sweep.tsv; [ -f "$T" ] || echo -e "point\tlevel\tratio_pct\tc_mbs\td_mbs\tstatus" > "$T"
one() { local name=$1 L=$2; grep -q "^$name	$L	" "$T" && return 0; quiet
  local o; o=$(taskset -c $CPU "$V/bin/$name" t --in "$F" --threads 1 --level "$L" 2>&1)
  echo -e "$name\t$L\t$(echo "$o" | awk '/Ratio:/{printf "%.3f", 100/$2}')\t$(echo "$o" | awk '/Encode:/{print $2}')\t$(echo "$o" | awk '/Decode:/{print $2}')\t$(echo "$o" | grep -c BIT-PERFECT)" >> "$T"
  echo "$(date -u +%FT%TZ) sweep $name L$L" >> "$W/STATUS"; }
echo "$(date -u +%FT%TZ) sweep start" >> "$W/STATUS"
for bw in 8 16 24 32; do for all in 0 1; do
  name="g_bw${bw}_all${all}"; build "$name" -DV_BW12=$bw -DV_BW13=$bw -DV_ALL12=$all -DV_ALL13=$all -DV_LAM=1
  one "$name" 12; one "$name" 13
done; done
for lam in 64 128 256; do   # 0.25 / 0.5 / 1.0 byte per token (K = 256 per byte); + 1 keeps the tie-break of S5
  name="opt_lam$lam"; build "$name" -DV_BW12=8 -DV_BW13=8 -DV_ALL12=0 -DV_ALL13=0 -DV_LAM=$((lam + 1))
  for L in 15 16 17 18; do one "$name" $L; done
done
echo "$(date -u +%FT%TZ) SWEEP DONE" >> "$W/STATUS"
