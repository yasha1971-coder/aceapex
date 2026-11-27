#!/usr/bin/env bash
# run_gpu_a1s.sh - GPU-A1 small block, check outside the selection (word of Yakiv 27.11 00:01): T2T-CHM13 and HPRC HG00438.1
#   (not chr1), open-profile archives with blocks 16 KiB / 64 KiB / 1 MiB (the default at --threads $T), nvCOMP zstd and LZ4
#   in the same gpu_a1 process, the same 10 000 windows x 16 KiB (seed 20261127) and 200 single windows (seed 777), every
#   window checked; no BGZF path. Otherwise as run_gpu_a1.sh (provenance, apt, pip nvCOMP, clone $REF, build, DONE, FETCHED,
#   self-delete).
set -uo pipefail
R=${R:-/root/gpu_a1s}; W=${W:-/root/gpu_a1_work}; REF=${REF:-gpu-a1}; WAIT_MIN=${WAIT_MIN:-30}; T=${THREADS:-$(nproc)}; mkdir -p "$R" "$W"; L=$R/run.log   # THREADS: the pod's vCPU (nproc shows the host)
export PATH="/usr/local/cuda/bin:$PATH"   # a non-login shell (ssh + nohup) on the RunPod image has no CUDA in PATH
log() { echo "$*" | tee -a "$L"; }
finish() {
    rc=$?; log "== exit rc $rc at $(date -u +%FT%TZ)"; grep '^A1ROW' "$L" > "$R/a1rows.tsv" 2>/dev/null
    { echo "SUMMARY GPU-A1S $(date -u +%FT%TZ) rc $rc"; grep -E '^\[a1\] |KILL' "$L"; } > "$R/SUMMARY.txt"; cat "$R/SUMMARY.txt"
    touch "$R/DONE"
    if [ "${KEEP:-0}" = 1 ]; then log "KEEP=1: the pod stays"; return; fi
    for i in $(seq $((WAIT_MIN * 6))); do [ -f "$R/FETCHED" ] && break; sleep 10; done
    log "removing pod ${RUNPOD_POD_ID:-?} ($( [ -f "$R/FETCHED" ] && echo 'results fetched' || echo "results NOT fetched after $WAIT_MIN min"))"
    # a shell started over ssh has no RUNPOD_* variables: take them from the container's first process (GPU-A1 26.11)
    for v in RUNPOD_POD_ID RUNPOD_API_KEY; do [ -n "${!v:-}" ] || export "$v=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n "s/^$v=//p")"; done
    if [ -n "${RUNPOD_POD_ID:-}" ] && command -v runpodctl >/dev/null; then   # 3.x: pod delete; the 1.x of pod images: remove pod
        runpodctl pod delete "$RUNPOD_POD_ID" 2>/dev/null || runpodctl remove pod "$RUNPOD_POD_ID"; else log "runpodctl or RUNPOD_POD_ID missing: remove the pod by hand"; fi
}
trap finish EXIT
# 1. provenance
{ echo "== GPU-A1 start $(date -u +%FT%TZ) pod ${RUNPOD_POD_ID:-none}"
  nvidia-smi --query-gpu=name,driver_version,clocks.max.sm,clocks.max.mem,clocks.sm,memory.total,power.limit --format=csv
  nvidia-smi -q -d CLOCK,PERFORMANCE | sed -n 1,40p; nvcc --version 2>/dev/null | tail -1
  lscpu | grep -E 'Model name|^CPU\(s\)'; echo "threads used: $T"; free -g | head -2; df -h "$W" | tail -1; } 2>&1 | tee -a "$L"
# 2. dependencies and builds
apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libzstd-dev libhts-dev tabix git make g++ curl ca-certificates python3-pip >/dev/null 2>&1 || { log "apt failed"; exit 4; }
pip install -q --break-system-packages nvidia-nvcomp-cu12 2>/dev/null || pip install -q nvidia-nvcomp-cu12 || { log "nvcomp pip failed"; exit 4; }
log "nvcomp $(pip show nvidia-nvcomp-cu12 2>/dev/null | awk '/^Version/{print $2}')"
NVL=$(find / -name 'libnvcomp.so*' -path '*nvcomp*' 2>/dev/null | head -1); NV=$(dirname "$(dirname "$NVL")"); NVLIB=$(basename "$NVL")
[ -f "$NV/include/nvcomp/zstd.h" ] || { log "nvCOMP headers not found"; exit 4; }
export LD_LIBRARY_PATH="$(dirname "$NVL"):${LD_LIBRARY_PATH:-}"
[ -d "$W/aceapex" ] || git clone -q --branch "$REF" https://github.com/yasha1971-coder/aceapex "$W/aceapex" || { log "clone failed"; exit 4; }
cd "$W/aceapex" && git fetch -q origin "$REF" && git checkout -q FETCH_HEAD && log "aceapex $(git rev-parse HEAD) ($REF)"
make -j"$T" aceapex >/dev/null 2>&1 && log "CLI $(./aceapex --version | head -1)" || { log "CLI build failed"; exit 4; }
nvcc -std=c++17 -O3 -arch=sm_90 -Isrc -I"$NV/include" scripts/gpu_a1.cu src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp \
    -L"$(dirname "$NVL")" -l:"$NVLIB" -lhts -lpthread -o "$W/gpu_a1" 2>"$R/nvcc.err" && log "gpu_a1 built" || { log "gpu_a1 build failed: $(tail -5 "$R/nvcc.err")"; exit 4; }
# 3. corpora (md5 pinned as in scripts/gpu_run.sh)
get() { local f=$W/$1 md5=$2 url=$3 gzmd5=${4:-}
    if [ ! -s "$f" ] || [ "$(md5sum < "$f" | cut -c1-32)" != "$md5" ]; then
        if [ -s "/workspace/aceapex_store/$1.gz" ]; then cp "/workspace/aceapex_store/$1.gz" "$f.gz" && log "$1.gz: copied from the volume (read only)"   # the store of gpu_run.sh on aceapex-desk
        else curl -sSL --retry 3 -o "$f.gz" "$url" || { log "$1: download failed ($url)"; return 1; }; fi
        [ -z "$gzmd5" ] || [ "$(md5sum < "$f.gz" | cut -c1-32)" = "$gzmd5" ] || { log "$1.gz md5 mismatch"; return 1; }
        gunzip -c "$f.gz" > "$f" && rm -f "$f.gz"; fi
    [ "$(md5sum < "$f" | cut -c1-32)" = "$md5" ] && log "$1: $(stat -c%s "$f") B, md5 ok" || { log "$1 md5 mismatch"; return 1; }; }
get t2t.fa cd1e52ce400c027ed0b7ab4b9d613f5a https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/009/914/755/GCA_009914755.4_T2T-CHM13v2.0/GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz 9280657210e4161147cbe13b022225b9 || exit 4
# HPRC HG00438.1 from the volume store; the gz sha256 pinned from runpod_inventory/volume_backup/manifest_volume.tsv (26.11)
H=/workspace/aceapex_store/hprc/HG00438.1.fa.gz
[ "$(sha256sum < "$H" | cut -c1-64)" = a5840157a6995c5fbc08698e52b614fbdf6f57a7245db944edb328a0b3e23ff8 ] || { log "HG00438.1.fa.gz sha256 mismatch"; exit 4; }
gunzip -c "$H" > "$W/hg00438.fa" && log "hg00438.fa: $(stat -c%s "$W/hg00438.fa") B, sha256 $(sha256sum < "$W/hg00438.fa" | cut -c1-16) (gz sha256 ok)" || exit 4
# 4. archives: open profile, blocks 16 KiB, 64 KiB and the default (1 MiB at --threads $T), each with a CPU round trip
mk() { local X=$1 tag=$2 bs=${3:-}
    env -i PATH="$PATH" AX_PROFILE=open ${bs:+ACEAPEX_BS=$bs} ./aceapex c --in "$W/$X.fa" --out "$W/$tag.aet" --threads "$T" >/dev/null 2>&1 || { log "$tag: encode failed"; return 1; }
    ./aceapex d --in "$W/$tag.aet" --out "$W/$tag.rt" >/dev/null 2>&1 && cmp -s "$W/$tag.rt" "$W/$X.fa" && rm -f "$W/$tag.rt" || { log "$tag: round trip FAILED"; return 1; }
    log "$tag: $(stat -c%s "$W/$tag.aet") B (CPU round trip ok)"; }
for X in t2t hg00438; do mk $X $X.bs16k 16384 || exit 4; mk $X $X.bs64k 65536 || exit 4; mk $X $X.bs1m || exit 4; done
log "t2t.bs1m must equal the table's t2t.open: 830777231 B"
# 5. ACE x 3 blocks, nvCOMP zstd and LZ4 in one process per genome
st=0
for X in t2t hg00438; do log "== gpu_a1 $X"
    "$W/gpu_a1" "$W/$X.bs16k.aet=ace16k,$W/$X.bs64k.aet=ace64k,$W/$X.bs1m.aet=ace1m" "$W/$X.fa" - 10000 16384 20 "$T" 2>&1 | tee -a "$L"; [ "${PIPESTATUS[0]}" = 0 ] || st=5; done
nvidia-smi --query-gpu=name,clocks.sm,clocks.mem,temperature.gpu,power.draw --format=csv | tee -a "$L"
exit $st
