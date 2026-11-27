#!/usr/bin/env bash
# run_fp1.sh - FULLPOD-1 load (after run_fp0.sh and the recalculated prediction in CALIBRATION), layout from $R/layout.env:
#   GPU job (hybrid1 fullgpu: full T2T decodes with on-device XXH3 + windows batches) on one feeder core, pinned buffers,
#   two modes: d2h=1 (result copied to host RAM) and d2h=0 (data and result in VRAM); CPU jobs on the other cores:
#   compression (T2T, enwik9, silesia.ref, level 2) on COMP, decompression + 10 000 ranges on DEC; NUMA binding if > 1 node.
#   Every job alone (FP_BASE s), then all together twice (FP_ALL s with d2h=1, FP_ALL s with d2h=0); a log line per second
#   (nvidia-smi dmon, cgroup cpu.stat, mpstat). On exit: DONE, wait for FETCHED, self-delete.
set -uo pipefail
R=${R:-/root/fp}; W=${W:-/root/hy1_work}; WAIT_MIN=${WAIT_MIN:-30}; T=${THREADS:-20}; FP_BASE=${FP_BASE:-60}; FP_ALL=${FP_ALL:-300}; L=$R/load.log
log() { echo "$*" | tee -a "$L"; }
finish() {
    rc=$?; log "== exit rc $rc at $(date -u +%FT%TZ)"; kill $(jobs -p) 2>/dev/null
    grep -h FPEND "$R"/fp_*.log > "$R/fpend.tsv" 2>/dev/null; touch "$R/DONE"
    if [ "${KEEP:-0}" = 1 ]; then log "KEEP=1: the pod stays"; return; fi
    for i in $(seq $((WAIT_MIN * 6))); do [ -f "$R/FETCHED" ] && break; sleep 10; done
    log "removing pod ($( [ -f "$R/FETCHED" ] && echo 'results fetched' || echo "results NOT fetched after $WAIT_MIN min"))"
    for v in RUNPOD_POD_ID RUNPOD_API_KEY; do [ -n "${!v:-}" ] || export "$v=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n "s/^$v=//p")"; done
    if [ -n "${RUNPOD_POD_ID:-}" ] && command -v runpodctl >/dev/null; then
        runpodctl pod delete "$RUNPOD_POD_ID" 2>/dev/null || runpodctl remove pod "$RUNPOD_POD_ID"; else log "runpodctl or RUNPOD_POD_ID missing: remove the pod by hand"; fi
}
trap finish EXIT
[ -f "$R/layout.env" ] || { log "no layout.env: run run_fp0.sh first"; exit 4; }
. "$R/layout.env"; NLIB=$(find / -name 'libnvcomp.so*' -path '*nvcomp*' 2>/dev/null | head -1); export LD_LIBRARY_PATH="$(dirname "$NLIB"):${LD_LIBRARY_PATH:-}"
log "== FULLPOD-1 load $(date -u +%FT%TZ): feeder $FEED, comp [$COMP] ($NCOMP), dec [$DEC] ($NDEC), NUMA nodes $NUMA_NODES, GPU node $GPU_NUMA, prefix '$NUMA_PREFIX'"
mon() { local tag=$1
    nvidia-smi dmon -s pucm -d 1 -o T > "$R/fp_${tag}_dmon.log" 2>&1 & echo $! > "$R/.mon1"
    ( p=$(awk '/usage_usec/{print $2}' /sys/fs/cgroup/cpu.stat); while sleep 1; do q=$(awk '/usage_usec/{print $2}' /sys/fs/cgroup/cpu.stat)
        echo "$(date -u +%T) pod_cpu_pct $(awk -v a=$p -v b=$q -v t=$T 'BEGIN{printf "%.1f", (b-a)/1e4/t}')"; p=$q; done ) > "$R/fp_${tag}_cpu.log" 2>&1 & echo $! > "$R/.mon2"
    mpstat -P ALL 1 > "$R/fp_${tag}_mpstat.log" 2>&1 & echo $! > "$R/.mon3"; }
unmon() { kill $(cat "$R/.mon1" "$R/.mon2" "$R/.mon3") 2>/dev/null; }
GPUJ() { taskset -c "$FEED" $NUMA_PREFIX "$W/hybrid1" fullgpu "$W/t2t.open.aet" "$W/t2t.fa" "$1" "$2"; }
COMPJ() { taskset -c "$COMP" $NUMA_PREFIX "$W/hybrid1" cpucomp "$NCOMP" "$1" "$W/t2t.fa" "$W/enwik9" "$W/silesia.ref.tar"; }
DECJ() { taskset -c "$DEC" $NUMA_PREFIX "$W/hybrid1" cpudec "$NDEC" "$1" "$W/t2t.def.aet" "$W/t2t.fa"; }
st=0
log "== base: each job alone, $FP_BASE s"
mon base_gpu;  GPUJ "$FP_BASE" 1 > "$R/fp_base_gpu.log" 2>&1 || st=5; unmon
mon base_gpuv; GPUJ "$FP_BASE" 0 > "$R/fp_base_gpuv.log" 2>&1 || st=5; unmon
mon base_comp; COMPJ "$FP_BASE" > "$R/fp_base_comp.log" 2>&1 || st=5; unmon
mon base_dec;  DECJ "$FP_BASE" > "$R/fp_base_dec.log" 2>&1 || st=5; unmon
grep -h FPEND "$R"/fp_base_*.log | tee -a "$L"; [ "$st" = 0 ] || { log "KILL in the base"; exit 5; }
for M in 1 0; do tag=all_d2h$M; log "== all together, GPU d2h=$M, $FP_ALL s"
    mon $tag; COMPJ "$FP_ALL" > "$R/fp_${tag}_comp.log" 2>&1 & PC=$!
    until grep -c roundtrip "$R/fp_${tag}_comp.log" 2>/dev/null | grep -q 3; do sleep 1; kill -0 $PC 2>/dev/null || break; done
    log "together window starts $(date -u +%T)"
    GPUJ "$FP_ALL" $M > "$R/fp_${tag}_gpu.log" 2>&1 & PG=$!; DECJ "$FP_ALL" > "$R/fp_${tag}_dec.log" 2>&1 & PD=$!
    wait $PG || st=5; wait $PD || st=5; wait $PC || st=5; unmon
    grep -h FPEND "$R"/fp_${tag}_*.log | tee -a "$L"; [ "$st" = 0 ] || { log "KILL together"; exit 5; }; done
exit $st
