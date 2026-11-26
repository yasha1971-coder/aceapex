#!/usr/bin/env bash
# run_gpu_a1h.sh - GPU-A1 hypotheses H1-H3 on a clean RunPod pod (H100), one script, after the deciding table (run_gpu_a1.sh):
#   1. provenance; 2. apt (no nvCOMP: ACE only), clone of aceapex at $REF, the CLI, scripts/gpu_a1h.cu with -DAXW_PROF (sm_90);
#   3. corpora with pinned md5 (from the volume store, as run_gpu_a1.sh); 4. open-profile archives: chr1 and T2T with the
#   default block (the table's archives: --threads $T), chr1 with ACEAPEX_BS=65536 and 16384 (the block-size floor of
#   one window), each with a CPU round trip; 5. gpu_a1h per archive: phases, V0 / V1 / V2 (H3), graphs (H1), whole-file
#   check; 6. results in $R; 7. on exit: DONE, wait for FETCHED, remove the pod (as run_gpu_a1.sh).
set -uo pipefail
R=${R:-/root/gpu_a1h}; W=${W:-/root/gpu_a1_work}; REF=${REF:-gpu-a1}; WAIT_MIN=${WAIT_MIN:-30}; T=${THREADS:-$(nproc)}; mkdir -p "$R" "$W"; L=$R/run.log   # THREADS: the pod's vCPU (nproc shows the host)
export PATH="/usr/local/cuda/bin:$PATH"   # a non-login shell (ssh + nohup) on the RunPod image has no CUDA in PATH
log() { echo "$*" | tee -a "$L"; }
finish() {
    rc=$?; log "== exit rc $rc at $(date -u +%FT%TZ)"; grep -E '^A1H' "$L" > "$R/a1h.tsv" 2>/dev/null
    { echo "SUMMARY GPU-A1H $(date -u +%FT%TZ) rc $rc"; grep -E '^\[a1h\]' "$L"; } > "$R/SUMMARY.txt"; cat "$R/SUMMARY.txt"
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
{ echo "== GPU-A1H start $(date -u +%FT%TZ) pod ${RUNPOD_POD_ID:-none}"
  nvidia-smi --query-gpu=name,driver_version,clocks.max.sm,clocks.max.mem,clocks.sm,memory.total,power.limit --format=csv
  nvcc --version 2>/dev/null | tail -1; lscpu | grep -E 'Model name|^CPU\(s\)'; echo "threads used: $T"; free -g | head -2; df -h "$W" | tail -1; } 2>&1 | tee -a "$L"
# 2. dependencies and builds
apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libzstd-dev git make g++ curl ca-certificates >/dev/null 2>&1 || { log "apt failed"; exit 4; }
[ -d "$W/aceapex" ] || git clone -q --branch "$REF" https://github.com/yasha1971-coder/aceapex "$W/aceapex" || { log "clone failed"; exit 4; }
cd "$W/aceapex" && git fetch -q origin "$REF" && git checkout -q FETCH_HEAD && log "aceapex $(git rev-parse HEAD) ($REF)"
make -j"$T" aceapex >/dev/null 2>&1 && log "CLI $(./aceapex --version | head -1)" || { log "CLI build failed"; exit 4; }
nvcc -std=c++17 -O3 -arch=sm_90 -DAXW_PROF -Isrc scripts/gpu_a1h.cu src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp -o "$W/gpu_a1h" 2>"$R/nvcc.err" \
    && log "gpu_a1h built" || { log "gpu_a1h build failed: $(tail -5 "$R/nvcc.err")"; exit 4; }
# 3. corpora (md5 pinned as in scripts/gpu_run.sh)
get() { local f=$W/$1 md5=$2 url=$3 gzmd5=${4:-}
    if [ ! -s "$f" ] || [ "$(md5sum < "$f" | cut -c1-32)" != "$md5" ]; then
        if [ -s "/workspace/aceapex_store/$1.gz" ]; then cp "/workspace/aceapex_store/$1.gz" "$f.gz" && log "$1.gz: copied from the volume (read only)"   # the store of gpu_run.sh on aceapex-desk
        else curl -sSL --retry 3 -o "$f.gz" "$url" || { log "$1: download failed ($url)"; return 1; }; fi
        [ -z "$gzmd5" ] || [ "$(md5sum < "$f.gz" | cut -c1-32)" = "$gzmd5" ] || { log "$1.gz md5 mismatch"; return 1; }
        gunzip -c "$f.gz" > "$f" && rm -f "$f.gz"; fi
    [ "$(md5sum < "$f" | cut -c1-32)" = "$md5" ] && log "$1: $(stat -c%s "$f") B, md5 ok" || { log "$1 md5 mismatch"; return 1; }; }
get chr1.fa 9465e0f0df6e2c6eb39729c39cee5465 https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/chr1.fa.gz || exit 4
get t2t.fa cd1e52ce400c027ed0b7ab4b9d613f5a https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/009/914/755/GCA_009914755.4_T2T-CHM13v2.0/GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz 9280657210e4161147cbe13b022225b9 || exit 4
# 4. archives: the open profile with the default block (as the table) and chr1 with 64 KiB and 16 KiB blocks
mk() { local X=$1 tag=$2 bs=${3:-}
    env -i PATH="$PATH" AX_PROFILE=open ${bs:+ACEAPEX_BS=$bs} ./aceapex c --in "$W/$X.fa" --out "$W/$tag.aet" --threads "$T" >/dev/null 2>&1 || { log "$tag: encode failed"; return 1; }
    ./aceapex d --in "$W/$tag.aet" --out "$W/$tag.rt" >/dev/null 2>&1 && cmp -s "$W/$tag.rt" "$W/$X.fa" && rm -f "$W/$tag.rt" || { log "$tag: round trip FAILED"; return 1; }
    log "$tag: $(stat -c%s "$W/$tag.aet") B (CPU round trip ok)"; }
mk chr1 chr1.open || exit 4; mk t2t t2t.open || exit 4; mk chr1 chr1.bs64k 65536 || exit 4; mk chr1 chr1.bs16k 16384 || exit 4
log "the table's archives (GPU-A1 run 2): chr1.open 62041847 B, t2t.open 830777231 B"
# 5. hypotheses
st=0
for A in chr1.open:chr1 t2t.open:t2t chr1.bs64k:chr1 chr1.bs16k:chr1; do tag=${A%%:*}; X=${A##*:}
    log "== gpu_a1h $tag"; "$W/gpu_a1h" "$W/$tag.aet" "$W/$X.fa" "$tag" 10000 16384 20 2>&1 | tee -a "$L"; [ "${PIPESTATUS[0]}" = 0 ] || st=5; done
nvidia-smi --query-gpu=name,clocks.sm,clocks.mem,temperature.gpu,power.draw --format=csv | tee -a "$L"
exit $st
