#!/bin/bash
# reproduce_paper5.sh — reproduce the min_match_len data-dependent lever (Paper 5).
# Reviewer: clone repo, obtain data by md5 (see DATA.md), run this. Judge = bit-perfect FNV.
#
# Paper 5 claim: min_match_len is a data-dependent decode-throughput lever whose magnitude
# scales with parse-fraction. Aggressive min_match reduces token count -> shorter parse+copy
# -> higher throughput, at a small ratio cost. Optimum is moderate (aggr), not extreme.
#
# Expected (H100, bs=16384, all bit-perfect FNV MATCHES):
#   FASTQ (copy-bound):    tuned 200 GB/s -> aggr 215 (+7.4%, ratio -1.7%)
#   enwik9 (moderate):     182 -> 188 (+2.7%, ratio +0.5%)
#   silesia (parse-bound): 53 -> 64  (+20.2%, parse -22%)

set -uo pipefail

# ---- config (edit paths to your data, see DATA.md for md5) ----
DIETGPU=${DIETGPU:-/workspace/dietgpu}
ZSTD_INC=${ZSTD_INC:-/workspace/lzbench-pr/lz/zstd/lib}   # zstd.h location
FASTQ=${FASTQ:-/workspace/data/NA12878_REAL.fastq}         # md5 9af9ffaa0e15
ENWIK9=${ENWIK9:-/workspace/data/enwik9}                   # md5 e206c3450ac9
SILESIA=${SILESIA:-/workspace/data/silesia.tar}

export ACEAPEX_BS=16384   # >16384 FAIL LOUD (32K-bug); 16384 = throughput optimum
export LD_LIBRARY_PATH=$DIETGPU/build/lib:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}

# ---- build (tuned baseline encoder + GPU decoder) ----
echo "=== BUILD ==="
g++ -O3 -march=native -funroll-loops -std=c++17 -Isrc -I$ZSTD_INC \
    -o aceapex_depth aceapex_depth.cpp -lpthread \
    /usr/lib/x86_64-linux-gnu/libzstd.so.1 || { echo "encoder build failed"; exit 1; }
nvcc -O3 -arch=sm_90 -I$DIETGPU -I. -Isrc -o e2e_dense dense.cu \
    -L$DIETGPU/build/lib -lgpu_ans -ldietgpu_utils -lpthread || { echo "decoder build failed"; exit 1; }
echo "build OK"

# ---- helper: run one (dataset, min_match config) and print throughput+ratio+split+FNV ----
run_one () {
  local SRC="$1" LABEL="$2"
  ./aceapex_depth c --in "$SRC" --out /tmp/p5.aet --threads 8 >/tmp/enc.log 2>&1
  local RATIO=$(grep -i "Ratio" /tmp/enc.log | head -1 | tr -s ' ')
  ./aceapex_depth d --in /tmp/p5.aet --out /tmp/p5_dec >/dev/null 2>&1
  local OUT=$(./e2e_dense streams.bin "$SRC" 32 2>&1)
  local GBS=$(echo "$OUT" | grep -oE '[0-9.]+ GB/s' | tail -1)
  local SPLIT=$(echo "$OUT" | grep -i SPLIT)
  local FNV=$(echo "$OUT" | grep -iE "MATCHES|DIFFERS" | head -1)
  printf "  %-8s %s | %s | %s | %s\n" "$LABEL" "$GBS" "$RATIO" "$SPLIT" "$FNV"
}

# ---- min_match configs via sed on a copy (restore after) ----
cp aceapex_depth.cpp /tmp/orig.cpp
set_minmatch () {  # args: a b c d (the four return values)
  cp /tmp/orig.cpp aceapex_depth.cpp
  sed -i "s/if (dist < 128)     return 12;/if (dist < 128)     return $1;/" aceapex_depth.cpp
  sed -i "s/if (dist < 16384)   return 16;/if (dist < 16384)   return $2;/" aceapex_depth.cpp
  sed -i "s/if (dist < 2097152) return 24;/if (dist < 2097152) return $3;/" aceapex_depth.cpp
  sed -i "s/return 32;/return $4;/" aceapex_depth.cpp
  g++ -O3 -march=native -funroll-loops -std=c++17 -Isrc -I$ZSTD_INC \
      -o aceapex_depth aceapex_depth.cpp -lpthread \
      /usr/lib/x86_64-linux-gnu/libzstd.so.1 2>/dev/null
}

for DS in "FASTQ:$FASTQ" "enwik9:$ENWIK9" "silesia:$SILESIA"; do
  NAME="${DS%%:*}"; PATH_="${DS#*:}"
  [ -f "$PATH_" ] || { echo "SKIP $NAME (not found: $PATH_)"; continue; }
  echo ""
  echo "=== $NAME ==="
  set_minmatch 12 16 24 32; run_one "$PATH_" "tuned"
  set_minmatch 24 32 48 64; run_one "$PATH_" "aggr"
  set_minmatch 48 96 128 192; run_one "$PATH_" "extreme"
done

cp /tmp/orig.cpp aceapex_depth.cpp   # restore tuned baseline
echo ""
echo "=== DONE. Paper 5: aggr should beat tuned; gain scales with parse-fraction ==="
echo "  FASTQ ~+7.4%, enwik9 ~+2.7%, silesia ~+20%. extreme WORSE than aggr (non-monotone)."
echo "  All rows must show MATCHES OK (bit-perfect). Optimum = aggr, not extreme."
