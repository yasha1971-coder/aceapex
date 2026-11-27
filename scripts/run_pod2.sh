#!/usr/bin/env bash
# run_pod2.sh - pod 2 of 27.11 (word of Yakiv: "do both, check everything, budget up to 25 $"), one H100 pod:
#   A. HYBRID-1 repeat with HYBRID-2: the CPU part through aceapex_decompress_region_mt (T2T, HG00438.1, open, block 1 MiB)
#   B. GPU-WIN-ENT base: the entropy phase of the windows call split by kernel (rANS pieces | open case/gap | open bases),
#      block 16 KiB archives of chr1 and T2T (gpu_a1h, AXW_MARK 7 / 8)
#   C. variant 1 base: full GPU decode in VRAM of the default profile (zstd frames through nvCOMP, library with
#      -DACEAPEX_GPU_NVCOMP) against the open profile, T2T, no windows thread (hybrid1_nv fullgpu ... 0 0)
#   D. ENC-5: gpu_sa_prototype as it is (8 MiB of chr1 and of enwik9)
# zstd 1.6.0 (the release's zstd since 2.6.5) from its GitHub release tarball, sha256 against the release .sha256 and the
# pin of scripts/package_linux.sh (2ba599ae...). vCPU = the cgroup quota (cpu.max), not nproc. DONE, FETCHED, self-delete.
set -uo pipefail
R=${R:-/root/pod2}; W=${W:-/root/pod2_work}; REF=${REF:-gpu-a1}; WAIT_MIN=${WAIT_MIN:-30}
Q=$(awk '{ if ($1 == "max") print 0; else print int($1 / $2) }' /sys/fs/cgroup/cpu.max 2>/dev/null); T=${THREADS:-${Q:-16}}; [ "$T" -gt 0 ] || T=16
mkdir -p "$R" "$W"; L=$R/run.log
export PATH="/usr/local/cuda/bin:$PATH"
log() { echo "$*" | tee -a "$L"; }
finish() {
    rc=$?; log "== exit rc $rc at $(date -u +%FT%TZ)"; grep -hE '^(HYROW|HYSUM|A1H|A1HPH|A1HES|A1HG|FPEND)' "$L" > "$R/rows.tsv" 2>/dev/null
    { echo "SUMMARY POD2 $(date -u +%FT%TZ) rc $rc"; grep -hE '^\[(hy|a1h)\] |^FPEND|KILL|ENC5|== ' "$L"; } > "$R/SUMMARY.txt" 2>/dev/null; touch "$R/DONE"
    if [ "${KEEP:-0}" = 1 ]; then log "KEEP=1: the pod stays"; return; fi
    for i in $(seq $((WAIT_MIN * 6))); do [ -f "$R/FETCHED" ] && break; sleep 10; done
    log "removing pod ($( [ -f "$R/FETCHED" ] && echo 'results fetched' || echo "results NOT fetched after $WAIT_MIN min"))"
    for v in RUNPOD_POD_ID RUNPOD_API_KEY; do [ -n "${!v:-}" ] || export "$v=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n "s/^$v=//p")"; done
    if [ -n "${RUNPOD_POD_ID:-}" ] && command -v runpodctl >/dev/null; then
        runpodctl pod delete "$RUNPOD_POD_ID" 2>/dev/null || runpodctl remove pod "$RUNPOD_POD_ID"; else log "runpodctl or RUNPOD_POD_ID missing: remove the pod by hand"; fi
}
trap finish EXIT
{ echo "== POD2 start $(date -u +%FT%TZ) pod ${RUNPOD_POD_ID:-none}"
  nvidia-smi --query-gpu=name,driver_version,clocks.max.sm,memory.total,pcie.link.gen.current,pcie.link.width.current --format=csv
  lscpu | grep -E 'Model name|^CPU\(s\)|NUMA node\(s\)'; echo "vCPU (cgroup quota): $T; cpu.max $(cat /sys/fs/cgroup/cpu.max 2>/dev/null)"; free -g | head -2; } 2>&1 | tee -a "$L"
apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git make g++ curl ca-certificates python3-pip libhts-dev >/dev/null 2>&1 || { log "apt failed"; exit 4; }
pip install -q --break-system-packages nvidia-nvcomp-cu12 2>/dev/null || pip install -q nvidia-nvcomp-cu12 || { log "nvcomp pip failed"; exit 4; }
NVL=$(find / -name 'libnvcomp.so*' -path '*nvcomp*' 2>/dev/null | head -1); NV=$(dirname "$(dirname "$NVL")"); NVLIB=$(basename "$NVL"); export LD_LIBRARY_PATH="$(dirname "$NVL"):${LD_LIBRARY_PATH:-}"
log "nvcomp $(pip show nvidia-nvcomp-cu12 2>/dev/null | awk '/^Version/{print $2}')"
Z=$W/zstd-1.6.0; ZU=https://github.com/facebook/zstd/releases/download/v1.6.0
if [ ! -f "$Z/lib/libzstd.a" ]; then
    curl -sSL -o "$W/zstd-1.6.0.tar.gz" "$ZU/zstd-1.6.0.tar.gz" && curl -sSL -o "$W/zstd-1.6.0.tar.gz.sha256" "$ZU/zstd-1.6.0.tar.gz.sha256" || { log "zstd download failed"; exit 4; }
    ( cd "$W" && sha256sum -c zstd-1.6.0.tar.gz.sha256 ) >> "$L" 2>&1 || { log "zstd 1.6.0 sha256 mismatch (release file)"; exit 4; }
    [ "$(sha256sum < "$W/zstd-1.6.0.tar.gz" | cut -c1-8)" = 2ba599ae ] || { log "zstd 1.6.0 sha256 differs from the pin of package_linux.sh"; exit 4; }
    tar -C "$W" -xzf "$W/zstd-1.6.0.tar.gz" && make -C "$Z/lib" -j"$T" libzstd.a >/dev/null 2>&1 || { log "zstd build failed"; exit 4; }; fi
log "zstd 1.6.0: release .sha256 ok, pin 2ba599ae ok"
[ -d "$W/aceapex" ] || git clone -q --branch "$REF" https://github.com/yasha1971-coder/aceapex "$W/aceapex" || { log "clone failed"; exit 4; }
cd "$W/aceapex" && git fetch -q origin "$REF" && git checkout -q FETCH_HEAD && log "aceapex $(git rev-parse HEAD) ($REF)"
make -j"$T" aceapex ZSTD_SRC="$Z" >/dev/null 2>&1 && log "CLI $(./aceapex --version | head -1)" || { log "CLI build failed"; exit 4; }
g++ -std=c++17 -O3 -march=native -I"$Z/lib" -Isrc -c src/aceapex_api.cpp -o "$W/api.o" || { log "api build failed"; exit 4; }
HB="scripts/hybrid1.cu src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp $W/api.o -L$(dirname "$NVL") -l:$NVLIB $Z/lib/libzstd.a -L/usr/local/cuda/lib64/stubs -lnvidia-ml -lpthread"
nvcc -std=c++17 -O3 -arch=sm_90 -Isrc -I"$NV/include" -I"$Z/lib" $HB -o "$W/hybrid1" 2>"$R/nvcc1.err" && log "hybrid1 built" || { log "hybrid1 build failed: $(tail -3 "$R/nvcc1.err")"; exit 4; }
nvcc -std=c++17 -O3 -arch=sm_90 -DACEAPEX_GPU_NVCOMP -Isrc -I"$NV/include" -I"$Z/lib" $HB -o "$W/hybrid1_nv" 2>"$R/nvcc2.err" && log "hybrid1_nv built (library with nvCOMP)" || { log "hybrid1_nv build failed: $(tail -3 "$R/nvcc2.err")"; exit 4; }
nvcc -std=c++17 -O3 -arch=sm_90 -DAXW_PROF -Isrc scripts/gpu_a1h.cu src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp -o "$W/gpu_a1h" 2>"$R/nvcc3.err" && log "gpu_a1h built" || { log "gpu_a1h build failed: $(tail -3 "$R/nvcc3.err")"; exit 4; }
nvcc -O3 -arch=sm_90 scripts/enc5_gpu_sa_prototype.cu -o "$W/gpu_sa" 2>"$R/nvcc4.err" && log "gpu_sa_prototype built (as it is, sha256 $(sha256sum < scripts/enc5_gpu_sa_prototype.cu | cut -c1-16))" || log "gpu_sa_prototype build failed: $(tail -3 "$R/nvcc4.err")"
# corpora
get() { local f=$W/$1 md5=$2 url=$3 gzmd5=${4:-}
    if [ ! -s "$f" ] || [ "$(md5sum < "$f" | cut -c1-32)" != "$md5" ]; then
        if [ -s "/workspace/aceapex_store/$1.gz" ]; then cp "/workspace/aceapex_store/$1.gz" "$f.gz"; else curl -sSL --retry 3 -o "$f.gz" "$url" || return 1; fi
        [ -z "$gzmd5" ] || [ "$(md5sum < "$f.gz" | cut -c1-32)" = "$gzmd5" ] || { log "$1.gz md5 mismatch"; return 1; }
        gunzip -c "$f.gz" > "$f" && rm -f "$f.gz"; fi
    [ "$(md5sum < "$f" | cut -c1-32)" = "$md5" ] && log "$1: $(stat -c%s "$f") B, md5 ok" || { log "$1 md5 mismatch"; return 1; }; }
get chr1.fa 9465e0f0df6e2c6eb39729c39cee5465 https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/chr1.fa.gz || exit 4
get t2t.fa cd1e52ce400c027ed0b7ab4b9d613f5a https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/009/914/755/GCA_009914755.4_T2T-CHM13v2.0/GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz 9280657210e4161147cbe13b022225b9 || exit 4
H=/workspace/aceapex_store/hprc/HG00438.1.fa.gz
[ "$(sha256sum < "$H" | cut -c1-64)" = a5840157a6995c5fbc08698e52b614fbdf6f57a7245db944edb328a0b3e23ff8 ] && gunzip -c "$H" > "$W/hg00438.fa" && log "hg00438.fa: gz sha256 ok" || { log "HG00438.1 mismatch"; exit 4; }
cp /workspace/data/enwik9 "$W/enwik9" && [ "$(sha256sum < "$W/enwik9" | cut -c1-64)" = 159b85351e5f76e60cbe32e04c677847a9ecba3adc79addab6f4c6c7aa3744bc ] && log "enwik9: sha256 ok" || { log "enwik9 mismatch"; exit 4; }
# archives (CPU round trip each); the open default block at --threads 20 = 1 MiB (the table's archives)
mk() { local X=$1 tag=$2 bs=$3 prof=$4
    env -i PATH="$PATH" ${prof:+AX_PROFILE=$prof} ${bs:+ACEAPEX_BS=$bs} ./aceapex c --in "$W/$X" --out "$W/$tag.aet" --threads 20 >/dev/null 2>&1 || { log "$tag: encode failed"; return 1; }
    ./aceapex d --in "$W/$tag.aet" --out "$W/$tag.rt" >/dev/null 2>&1 && cmp -s "$W/$tag.rt" "$W/$X" && rm -f "$W/$tag.rt" || { log "$tag: round trip FAILED"; return 1; }
    log "$tag: $(stat -c%s "$W/$tag.aet") B (CPU round trip ok)"; }
mk t2t.fa t2t.open "" open || exit 4; mk hg00438.fa hg00438.open "" open || exit 4; mk t2t.fa t2t.def "" "" || exit 4
mk chr1.fa chr1.bs16k 16384 open || exit 4; mk t2t.fa t2t.bs16k 16384 open || exit 4
log "pinned sizes: t2t.open 830777231, hg00438.open 758943628, t2t.bs16k 853265321 (GPU-A1); t2t.def 806108652 was built with zstd 1.5.7 (FULLPOD-1)"
st=0
log "== A. HYBRID-1 repeat with region_mt (vCPU $T)"
for X in t2t hg00438; do "$W/hybrid1" hybrid "$X" "$W/$X.open.aet" "$W/$X.fa" "$T" 5 256 2>&1 | tee -a "$L"; [ "${PIPESTATUS[0]}" = 0 ] || st=5; done
log "== B. GPU-WIN-ENT base: entropy split by kernel"
for X in chr1 t2t; do "$W/gpu_a1h" "$W/$X.bs16k.aet" "$W/$X.fa" "$X.bs16k" 10000 16384 20 2>&1 | tee -a "$L"; [ "${PIPESTATUS[0]}" = 0 ] || st=5; done
log "== C. variant 1 base: full GPU decode in VRAM, default (nvCOMP zstd frames) vs open, T2T, 30 s each, no windows"
"$W/hybrid1_nv" fullgpu "$W/t2t.def.aet" "$W/t2t.fa" 30 0 0 2>&1 | grep -E 'FPEND' | sed 's/^/default /' | tee -a "$L"; [ "${PIPESTATUS[0]}" = 0 ] || st=5
"$W/hybrid1_nv" fullgpu "$W/t2t.open.aet" "$W/t2t.fa" 30 0 0 2>&1 | grep -E 'FPEND' | sed 's/^/open    /' | tee -a "$L"; [ "${PIPESTATUS[0]}" = 0 ] || st=5
log "== D. ENC-5: gpu_sa_prototype as it is, 8 MiB"
for X in chr1.fa enwik9; do timeout 600 "$W/gpu_sa" "$W/$X" 8388608 2>&1 | sed "s/^/ENC5 $X: /" | tail -20 | tee -a "$L"; log "ENC5 $X rc ${PIPESTATUS[0]}"; done
nvidia-smi --query-gpu=name,clocks.sm,clocks.mem,temperature.gpu,power.draw --format=csv | tee -a "$L"
[ "$st" = 0 ] || log "KILL: an output differs (see above)"
exit $st
