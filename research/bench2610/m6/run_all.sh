#!/usr/bin/env bash
# run_all.sh - PROTOCOL_M6 v1.1 main run: N = 50, 100, 200, 558 one after another, every phase of run_n.sh in order
# (requests + truth, create, integrity, H5, counters, timing under the silence gate, perf). Stops at the first failed
# integrity. Progress in logs/run_all.log.
set -uo pipefail
ulimit -c 0
D=$(cd "$(dirname "$0")" && pwd); LOG=$D/logs/run_all.log; mkdir -p $D/logs
echo "# run_all start $(date -u +%FT%TZ) protocol $(cut -c1-64 $D/PROTOCOL_M6.sha256) aceapex $(git -C $D rev-parse --short HEAD)" >> $LOG
for N in 50 100 200 558; do
  for ph in req create integrity h5 counters measure perf; do
    echo "## N $N $ph start $(date -u +%FT%TZ)" >> $LOG
    bash $D/run_n.sh $N $ph >> $LOG 2>&1; rc=$?
    echo "## N $N $ph end $(date -u +%FT%TZ) exit $rc" >> $LOG
    if [ $ph = integrity ] && [ $rc != 0 ]; then echo "## STOP: integrity failed for N $N" >> $LOG; exit 1; fi
  done
done
echo "# run_all done $(date -u +%FT%TZ)" >> $LOG
