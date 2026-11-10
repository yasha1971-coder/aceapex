#!/bin/bash
# E2-ENC: one detached measurement chain (setsid nohup), progress in $W/STATUS. Usage: bash research/e2enc/chain.sh <cmd>...
#   each <cmd> is "STEP|BIN|LEVELS|RUNS" (corpora: the dev set); stops at the first failing step.
set -euo pipefail
W=/home/aeterna/pubrepo/.wk/e2work; cd /home/aeterna/pubrepo/.wk/e2enc
for spec in "$@"; do
  IFS='|' read -r STEP BIN LEVELS RUNS <<< "$spec"
  BIN="$BIN" bash research/e2enc/bench.sh "$STEP" "$W/res" "$LEVELS" "$RUNS" >> "$W/chain.log" 2>&1 || { echo "$(date -u +%FT%TZ) $STEP FAILED rc=$?" >> "$W/STATUS"; exit 1; }
done
echo "$(date -u +%FT%TZ) CHAIN DONE" >> "$W/STATUS"
