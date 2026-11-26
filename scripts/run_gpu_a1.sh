#!/usr/bin/env bash
# run_gpu_a1.sh - GPU-A1 on a clean RunPod pod (H100, CUDA 12.x image), one script:
#   1. provenance: nvidia-smi (model, driver, clocks, memory), CPU, RAM; 2. dependencies (apt: libzstd-dev libhts-dev tabix;
#   pip: nvidia-nvcomp-cu12), clone of aceapex at $REF (branch gpu-a1), the CLI and scripts/gpu_a1.cu (sm_90);
#   3. corpora with pinned md5 (hg38 chr1, T2T-CHM13 v2.0 - as scripts/gpu_run.sh); 4. per corpus: the open-profile
#   archive (AX_PROFILE=open, the profile of the windows API) and bgzip -i (BGZF + .gzi); 5. gpu_a1 on chr1 and T2T
#   (10 000 windows x 16 KiB, seed 20261127, 20 repeats x 2 blocks, all CPU threads); 6. results in $R (run.log,
#   a1rows.tsv, SUMMARY); 7. on exit (done, failed or interrupted): DONE marker, wait up to WAIT_MIN minutes for the
#   orchestrator to fetch $R and touch $R/FETCHED, then `runpodctl remove pod $RUNPOD_POD_ID` (KEEP=1 keeps the pod).
# The pod deletes itself: the orchestrator on ace-core also arms a timer that removes this pod by id (GPU-A1 step 3).
set -uo pipefail
R=${R:-/root/gpu_a1}; W=${W:-/root/gpu_a1_work}; REF=${REF:-gpu-a1}; WAIT_MIN=${WAIT_MIN:-30}; mkdir -p "$R" "$W"; L=$R/run.log
log() { echo "$*" | tee -a "$L"; }
finish() {
    rc=$?; log "== exit rc $rc at $(date -u +%FT%TZ)"; grep '^A1ROW' "$L" > "$R/a1rows.tsv" 2>/dev/null
    { echo "SUMMARY GPU-A1 $(date -u +%FT%TZ) rc $rc"; grep -E '^\[a1\] (ace|zstd|lz4|bgzf) |KILL|all paths' "$L"; } > "$R/SUMMARY.txt"; cat "$R/SUMMARY.txt"
    touch "$R/DONE"
    if [ "${KEEP:-0}" = 1 ]; then log "KEEP=1: the pod stays"; return; fi
    for i in $(seq $((WAIT_MIN * 6))); do [ -f "$R/FETCHED" ] && break; sleep 10; done
    log "removing pod ${RUNPOD_POD_ID:-?} ($( [ -f "$R/FETCHED" ] && echo 'results fetched' || echo "results NOT fetched after $WAIT_MIN min"))"
    if [ -n "${RUNPOD_POD_ID:-}" ] && command -v runpodctl >/dev/null; then runpodctl remove pod "$RUNPOD_POD_ID"; else log "runpodctl or RUNPOD_POD_ID missing: remove the pod by hand"; fi
}
trap finish EXIT
# 1. provenance
{ echo "== GPU-A1 start $(date -u +%FT%TZ) pod ${RUNPOD_POD_ID:-none}"
  nvidia-smi --query-gpu=name,driver_version,clocks.max.sm,clocks.max.mem,clocks.sm,memory.total,power.limit --format=csv
  nvidia-smi -q -d CLOCK,PERFORMANCE | sed -n 1,40p; nvcc --version 2>/dev/null | tail -1
  lscpu | grep -E 'Model name|^CPU\(s\)'; free -g | head -2; df -h "$W" | tail -1; } 2>&1 | tee -a "$L"
# 2. dependencies and builds
apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libzstd-dev libhts-dev tabix git make g++ curl python3-pip >/dev/null 2>&1 || { log "apt failed"; exit 4; }
pip install -q --break-system-packages nvidia-nvcomp-cu12 2>/dev/null || pip install -q nvidia-nvcomp-cu12 || { log "nvcomp pip failed"; exit 4; }
log "nvcomp $(pip show nvidia-nvcomp-cu12 2>/dev/null | awk '/^Version/{print $2}')"
NVL=$(find / -name 'libnvcomp.so*' -path '*nvcomp*' 2>/dev/null | head -1); NV=$(dirname "$(dirname "$NVL")"); NVLIB=$(basename "$NVL")
[ -f "$NV/include/nvcomp/zstd.h" ] || { log "nvCOMP headers not found"; exit 4; }
export LD_LIBRARY_PATH="$(dirname "$NVL"):${LD_LIBRARY_PATH:-}"
[ -d "$W/aceapex" ] || git clone -q --branch "$REF" https://github.com/yasha1971-coder/aceapex "$W/aceapex" || { log "clone failed"; exit 4; }
cd "$W/aceapex" && log "aceapex $(git rev-parse HEAD) ($REF)"
make -j"$(nproc)" aceapex >/dev/null 2>&1 && log "CLI $(./aceapex --version | head -1)" || { log "CLI build failed"; exit 4; }
nvcc -std=c++17 -O3 -arch=sm_90 -Isrc -I"$NV/include" scripts/gpu_a1.cu src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp \
    -L"$(dirname "$NVL")" -l:"$NVLIB" -lhts -lpthread -o "$W/gpu_a1" 2>"$R/nvcc.err" && log "gpu_a1 built" || { log "gpu_a1 build failed: $(tail -5 "$R/nvcc.err")"; exit 4; }
# 3. corpora (md5 pinned as in scripts/gpu_run.sh)
get() { local f=$W/$1 md5=$2 url=$3 gzmd5=${4:-}
    if [ ! -s "$f" ] || [ "$(md5sum < "$f" | cut -c1-32)" != "$md5" ]; then
        curl -sL --retry 3 -o "$f.gz" "$url" || return 1
        [ -z "$gzmd5" ] || [ "$(md5sum < "$f.gz" | cut -c1-32)" = "$gzmd5" ] || { log "$1.gz md5 mismatch"; return 1; }
        gunzip -c "$f.gz" > "$f" && rm -f "$f.gz"; fi
    [ "$(md5sum < "$f" | cut -c1-32)" = "$md5" ] && log "$1: $(stat -c%s "$f") B, md5 ok" || { log "$1 md5 mismatch"; return 1; }; }
get chr1.fa 9465e0f0df6e2c6eb39729c39cee5465 https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/chr1.fa.gz || exit 4
get t2t.fa cd1e52ce400c027ed0b7ab4b9d613f5a https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/009/914/755/GCA_009914755.4_T2T-CHM13v2.0/GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz 9280657210e4161147cbe13b022225b9 || exit 4
# 4. archives: open profile (ACEAPEX windows API) and BGZF + .gzi
for X in chr1 t2t; do
    env -i PATH="$PATH" AX_PROFILE=open ./aceapex c --in "$W/$X.fa" --out "$W/$X.open.aet" --threads "$(nproc)" >/dev/null 2>&1 || { log "$X: encode failed"; exit 4; }
    ./aceapex d --in "$W/$X.open.aet" --out "$W/$X.rt" >/dev/null 2>&1 && cmp -s "$W/$X.rt" "$W/$X.fa" && rm -f "$W/$X.rt" || { log "$X: open archive round trip FAILED"; exit 4; }
    bgzip -@ "$(nproc)" -i -c "$W/$X.fa" > "$W/$X.fa.bgz" || { log "$X: bgzip failed"; exit 4; }
    log "$X: open archive $(stat -c%s "$W/$X.open.aet") B (CPU round trip ok), bgzf $(stat -c%s "$W/$X.fa.bgz") + gzi $(stat -c%s "$W/$X.fa.bgz.gzi") B"
done
log "t2t.open pinned size in scripts/gpu_run.sh: 853265321 B"
# 5. the deciding table
st=0
for X in chr1 t2t; do log "== gpu_a1 $X"; "$W/gpu_a1" "$W/$X.open.aet" "$W/$X.fa" "$W/$X.fa.bgz" 10000 16384 20 "$(nproc)" 2>&1 | tee -a "$L"; [ "${PIPESTATUS[0]}" = 0 ] || st=5; done
nvidia-smi --query-gpu=name,clocks.sm,clocks.mem,temperature.gpu,power.draw --format=csv | tee -a "$L"
exit $st
