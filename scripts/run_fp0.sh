#!/usr/bin/env bash
# run_fp0.sh - FULLPOD-1 step 0 (word of Yakiv 27.11 06:52), on the pod of run_hy1.sh, before any FULLPOD load:
#   1. environment: lscpu, numactl -H, vCPU (cgroup cpu.max, cpuset), nvidia-smi -q PCIe gen / width, nvidia-smi topo -m
#   2. PCIe as measured: H2D / D2H, pinned and pageable, 64 MiB - 1 GiB (hybrid1 pcie)
#   3. host memory copy: 1, N/2, N threads (hybrid1 memcpy N)
#   4. GDS: gdscheck -p if present, else recorded as absent
#   + the CPU layout for the load (layout.env): one GPU feeder core, the CPU jobs on the rest, on the GPU's NUMA node
# Rebuilds hybrid1 at $REF (the pcie / memcpy modes and the VRAM-only GPU job). No load, no self-delete (run_fp1.sh does).
set -uo pipefail
R=${R:-/root/fp}; W=${W:-/root/hy1_work}; REF=${REF:-gpu-a1}; T=${THREADS:-20}; mkdir -p "$R"; L=$R/step0.log
export PATH="/usr/local/cuda/bin:$PATH"
log() { echo "$*" | tee -a "$L"; }
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq numactl >/dev/null 2>&1 || log "numactl install failed"
NVL=$(find / -name 'libnvcomp.so*' -path '*nvcomp*' 2>/dev/null | head -1); NV=$(dirname "$(dirname "$NVL")"); NVLIB=$(basename "$NVL"); export LD_LIBRARY_PATH="$(dirname "$NVL"):${LD_LIBRARY_PATH:-}"
Z=$W/zstd-1.5.7
cd "$W/aceapex" && git fetch -q origin "$REF" && git checkout -q FETCH_HEAD && log "aceapex $(git rev-parse HEAD) ($REF)"
nvcc -std=c++17 -O3 -arch=sm_90 -Isrc -I"$NV/include" -I"$Z/lib" scripts/hybrid1.cu src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp "$W/aceapex_api.o" \
    -L"$(dirname "$NVL")" -l:"$NVLIB" "$Z/lib/libzstd.a" -L/usr/local/cuda/lib64/stubs -lnvidia-ml -lpthread -o "$W/hybrid1" 2>"$R/nvcc.err" && log "hybrid1 rebuilt" || { log "hybrid1 build failed: $(tail -3 "$R/nvcc.err")"; exit 4; }
log "== 1. environment $(date -u +%FT%TZ)"
{ lscpu; echo; numactl -H; echo; echo "nproc (host view): $(nproc)"; echo "cgroup cpu.max: $(cat /sys/fs/cgroup/cpu.max 2>/dev/null)"
  echo "cpuset.cpus.effective: $(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null)"; echo "cpuset.mems.effective: $(cat /sys/fs/cgroup/cpuset.mems.effective 2>/dev/null)"
  echo; nvidia-smi -q -d PCI 2>/dev/null | grep -iE 'Generation|Width|Max|Current|Bus Id' ; echo; nvidia-smi topo -m; } >> "$L" 2>&1
grep -E 'Model name|^CPU\(s\)|NUMA node\(s\)|Thread|Socket|available:' "$L" | tee -a "$R/summary.txt"
log "== 2. PCIe"; "$W/hybrid1" pcie 2>&1 | tee -a "$L" "$R/summary.txt"
# the GPU's NUMA node and CPU affinity (nvidia-smi topo -m, row GPU0), intersected with the container's cpuset
AFF=$(nvidia-smi topo -m | awk '/^GPU0/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$/ && $i ~ /-/) {print $i; exit}}')
NODE=$(nvidia-smi topo -m | awk '/^GPU0/{print $(NF-1)}'); NN=$(numactl -H | awk '/^available:/{print $2}')
expand() { echo "$1" | tr ',' '\n' | awk -F- '{if(NF==2) for(i=$1;i<=$2;i++) print i; else print $1}'; }
CS=$(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || echo "0-$(($(nproc)-1))")
CPUS=$(comm -12 <(expand "${AFF:-$CS}" | sort) <(expand "$CS" | sort) | sort -n | head -n "$T" | tr '\n' ' ')
set -- $CPUS; FEED=$1; shift; HALF=$(( ($# + 1) / 2 )); COMP=$(echo "$@" | tr ' ' '\n' | head -n "$HALF" | paste -sd,); DEC=$(echo "$@" | tr ' ' '\n' | tail -n +"$((HALF + 1))" | paste -sd,)
{ echo "NUMA_NODES=$NN"; echo "GPU_NUMA=${NODE:-?}"; echo "GPU_CPU_AFFINITY=${AFF:-none}"; echo "FEED=$FEED"; echo "COMP=$COMP"; echo "DEC=$DEC"
  echo "NCOMP=$(echo "$COMP" | tr ',' '\n' | grep -c .)"; echo "NDEC=$(echo "$DEC" | tr ',' '\n' | grep -c .)"
  if [ "${NN:-1}" -gt 1 ] && [[ "${NODE:-}" =~ ^[0-9]+$ ]]; then echo "NUMA_PREFIX=\"numactl --membind=$NODE\""; else echo "NUMA_PREFIX=\"\""; fi; } > "$R/layout.env"
log "layout: $(tr '\n' ' ' < "$R/layout.env")"
log "== 3. host memory copy"; MB=$(grep -oP 'NUMA_PREFIX="\K[^"]*' "$R/layout.env")
taskset -c "$FEED,$COMP,$DEC" $MB "$W/hybrid1" memcpy "$T" 2>&1 | tee -a "$L" "$R/summary.txt"
log "== 4. GDS"; G=$(ls /usr/local/cuda*/gds/tools/gdscheck* 2>/dev/null | head -1)
if [ -n "$G" ]; then "$G" -p >> "$L" 2>&1; log "gdscheck -p rc $? ($G)"; else log "GDS: gdscheck not present in the image - skipped"; fi
grep -E 'GDS|gdscheck' "$L" | tail -2 >> "$R/summary.txt"
touch "$R/STEP0_DONE"; log "== step 0 done $(date -u +%FT%TZ)"
