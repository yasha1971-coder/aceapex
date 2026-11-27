#!/usr/bin/env bash
# run_hy1.sh - one H100 pod (word of Yakiv 27.11 06:38): B16 (block 16 KiB on a third genome, HPRC HG00621.1), HYBRID-1
# (full decompression into host RAM: CPU only, GPU only, both at once; the same for nvCOMP zstd 16/64 KiB chunks) on T2T and
# HG00438.1, then FULLPOD-1 (every job alone, then all together for 10 minutes, a log line per second).
#   zstd 1.5.7 (the release's zstd) from its GitHub release tarball, sha256 checked against the release's .sha256 file:
#   the CLI, the CPU library in hybrid1 and the libzstd side of the nvCOMP hybrid use it.
#   Results in $R; on exit DONE, wait for FETCHED, self-delete (as run_gpu_a1.sh). THREADS = the pod's vCPU (nproc shows the host).
set -uo pipefail
R=${R:-/root/hy1}; W=${W:-/root/hy1_work}; REF=${REF:-gpu-a1}; WAIT_MIN=${WAIT_MIN:-30}; T=${THREADS:-20}; FP_BASE=${FP_BASE:-90}; FP_ALL=${FP_ALL:-600}
mkdir -p "$R" "$W"; L=$R/run.log
export PATH="/usr/local/cuda/bin:$PATH"
log() { echo "$*" | tee -a "$L"; }
finish() {
    rc=$?; log "== exit rc $rc at $(date -u +%FT%TZ)"; kill $(jobs -p) 2>/dev/null; grep -hE '^(A1ROW|HYROW|HYSUM|FPEND)' "$L" "$R"/fp_*.log > "$R/rows.tsv" 2>/dev/null
    { echo "SUMMARY HY1 $(date -u +%FT%TZ) rc $rc"; grep -hE '^\[(a1|hy)\] |^FPEND|KILL' "$L" "$R"/fp_*.log; } > "$R/SUMMARY.txt" 2>/dev/null; cat "$R/SUMMARY.txt"
    touch "$R/DONE"
    if [ "${KEEP:-0}" = 1 ]; then log "KEEP=1: the pod stays"; return; fi
    for i in $(seq $((WAIT_MIN * 6))); do [ -f "$R/FETCHED" ] && break; sleep 10; done
    log "removing pod ${RUNPOD_POD_ID:-?} ($( [ -f "$R/FETCHED" ] && echo 'results fetched' || echo "results NOT fetched after $WAIT_MIN min"))"
    for v in RUNPOD_POD_ID RUNPOD_API_KEY; do [ -n "${!v:-}" ] || export "$v=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n "s/^$v=//p")"; done
    if [ -n "${RUNPOD_POD_ID:-}" ] && command -v runpodctl >/dev/null; then
        runpodctl pod delete "$RUNPOD_POD_ID" 2>/dev/null || runpodctl remove pod "$RUNPOD_POD_ID"; else log "runpodctl or RUNPOD_POD_ID missing: remove the pod by hand"; fi
}
trap finish EXIT
# 1. provenance
{ echo "== HY1 start $(date -u +%FT%TZ) pod ${RUNPOD_POD_ID:-none}"
  nvidia-smi --query-gpu=name,driver_version,clocks.max.sm,clocks.max.mem,memory.total,power.limit,pcie.link.gen.max,pcie.link.width.max --format=csv
  nvcc --version 2>/dev/null | tail -1; lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Socket'; echo "vCPU used: $T (cgroup cpu.max: $(cat /sys/fs/cgroup/cpu.max 2>/dev/null))"
  free -g | head -2; df -h "$W" | tail -1; } 2>&1 | tee -a "$L"
# 2. dependencies, zstd 1.5.7, builds
apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git make g++ curl ca-certificates python3-pip sysstat libhts-dev >/dev/null 2>&1 || { log "apt failed"; exit 4; }
pip install -q --break-system-packages nvidia-nvcomp-cu12 2>/dev/null || pip install -q nvidia-nvcomp-cu12 || { log "nvcomp pip failed"; exit 4; }
NVL=$(find / -name 'libnvcomp.so*' -path '*nvcomp*' 2>/dev/null | head -1); NV=$(dirname "$(dirname "$NVL")"); NVLIB=$(basename "$NVL"); export LD_LIBRARY_PATH="$(dirname "$NVL"):${LD_LIBRARY_PATH:-}"
log "nvcomp $(pip show nvidia-nvcomp-cu12 2>/dev/null | awk '/^Version/{print $2}') ($NVL)"
Z=$W/zstd-1.5.7; ZU=https://github.com/facebook/zstd/releases/download/v1.5.7
if [ ! -f "$Z/lib/libzstd.a" ]; then
    curl -sSL -o "$W/zstd-1.5.7.tar.gz" "$ZU/zstd-1.5.7.tar.gz" && curl -sSL -o "$W/zstd-1.5.7.tar.gz.sha256" "$ZU/zstd-1.5.7.tar.gz.sha256" || { log "zstd download failed"; exit 4; }
    ( cd "$W" && sha256sum -c zstd-1.5.7.tar.gz.sha256 ) >> "$L" 2>&1 || { log "zstd 1.5.7 sha256 mismatch"; exit 4; }
    tar -C "$W" -xzf "$W/zstd-1.5.7.tar.gz" && make -C "$Z/lib" -j"$T" libzstd.a >/dev/null 2>&1 || { log "zstd build failed"; exit 4; }; fi
log "zstd 1.5.7: $(cut -c1-16 "$W/zstd-1.5.7.tar.gz.sha256") (release .sha256 ok), $Z/lib/libzstd.a"
[ -d "$W/aceapex" ] || git clone -q --branch "$REF" https://github.com/yasha1971-coder/aceapex "$W/aceapex" || { log "clone failed"; exit 4; }
cd "$W/aceapex" && git fetch -q origin "$REF" && git checkout -q FETCH_HEAD && log "aceapex $(git rev-parse HEAD) ($REF)"
make -j"$T" aceapex ZSTD_SRC="$Z" >/dev/null 2>&1 && log "CLI $(./aceapex --version | head -1)" || { log "CLI build failed"; exit 4; }
g++ -std=c++17 -O3 -march=native -I"$Z/lib" -Isrc -c src/aceapex_api.cpp -o "$W/aceapex_api.o" || { log "api build failed"; exit 4; }
nvcc -std=c++17 -O3 -arch=sm_90 -Isrc -I"$NV/include" -I"$Z/lib" scripts/hybrid1.cu src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp "$W/aceapex_api.o" \
    -L"$(dirname "$NVL")" -l:"$NVLIB" "$Z/lib/libzstd.a" -L/usr/local/cuda/lib64/stubs -lnvidia-ml -lpthread -o "$W/hybrid1" 2>"$R/nvcc_hy.err" && log "hybrid1 built" || { log "hybrid1 build failed: $(tail -5 "$R/nvcc_hy.err")"; exit 4; }
nvcc -std=c++17 -O3 -arch=sm_90 -Isrc -I"$NV/include" scripts/gpu_a1.cu src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp \
    -L"$(dirname "$NVL")" -l:"$NVLIB" -lhts -lpthread -o "$W/gpu_a1" 2>"$R/nvcc_a1.err" && log "gpu_a1 built" || { log "gpu_a1 build failed: $(tail -5 "$R/nvcc_a1.err")"; exit 4; }
# 3. corpora: T2T (md5), HPRC from the volume store (gz sha256 from runpod_inventory/volume_backup/manifest_volume.tsv), enwik9 (volume),
#    silesia = the reference of CLAUDE.md section 1 (corpus-collection, sha256 a667bac8...)
get() { local f=$W/$1 md5=$2 url=$3 gzmd5=${4:-}
    if [ ! -s "$f" ] || [ "$(md5sum < "$f" | cut -c1-32)" != "$md5" ]; then
        if [ -s "/workspace/aceapex_store/$1.gz" ]; then cp "/workspace/aceapex_store/$1.gz" "$f.gz"; else curl -sSL --retry 3 -o "$f.gz" "$url" || return 1; fi
        [ -z "$gzmd5" ] || [ "$(md5sum < "$f.gz" | cut -c1-32)" = "$gzmd5" ] || { log "$1.gz md5 mismatch"; return 1; }
        gunzip -c "$f.gz" > "$f" && rm -f "$f.gz"; fi
    [ "$(md5sum < "$f" | cut -c1-32)" = "$md5" ] && log "$1: $(stat -c%s "$f") B, md5 ok" || { log "$1 md5 mismatch"; return 1; }; }
get t2t.fa cd1e52ce400c027ed0b7ab4b9d613f5a https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/009/914/755/GCA_009914755.4_T2T-CHM13v2.0/GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz 9280657210e4161147cbe13b022225b9 || exit 4
hprc() { local X=$1 gz=/workspace/aceapex_store/hprc/$2.fa.gz sha=$3
    [ "$(sha256sum < "$gz" | cut -c1-64)" = "$sha" ] || { log "$2.fa.gz sha256 mismatch"; return 1; }
    gunzip -c "$gz" > "$W/$X.fa" && log "$X.fa ($2): $(stat -c%s "$W/$X.fa") B, sha256 $(sha256sum < "$W/$X.fa" | cut -c1-16) (gz sha256 ok)"; }
hprc hg00438 HG00438.1 a5840157a6995c5fbc08698e52b614fbdf6f57a7245db944edb328a0b3e23ff8 || exit 4
hprc hg00621 HG00621.1 bb7d30232f423cabf8d2ebf7443d15aa42bdbfe826424e89ac5f0ee33b0bc780 || exit 4
cp /workspace/data/enwik9 "$W/enwik9" && [ "$(sha256sum < "$W/enwik9" | cut -c1-64)" = 159b85351e5f76e60cbe32e04c677847a9ecba3adc79addab6f4c6c7aa3744bc ] && log "enwik9: sha256 ok" || { log "enwik9 sha256 mismatch"; exit 4; }
curl -sSL https://github.com/DataCompression/corpus-collection/raw/main/Silesia-Corpus/silesia.tar.gz | gunzip -c > "$W/silesia.ref.tar"
[ "$(sha256sum < "$W/silesia.ref.tar" | cut -c1-8)" = a667bac8 ] && [ "$(stat -c%s "$W/silesia.ref.tar")" = 211947520 ] && log "silesia.ref.tar: 211947520 B, sha256 a667bac8 (section 1 reference)" || { log "silesia reference mismatch"; exit 4; }
# 4. archives (CPU round trip each): open profile default block (t2t, hg00438), open 16 KiB (hg00621, B16), default profile T2T (FULLPOD cpudec)
mk() { local X=$1 tag=$2 bs=$3 prof=$4
    env -i PATH="$PATH" ${prof:+AX_PROFILE=$prof} ${bs:+ACEAPEX_BS=$bs} ./aceapex c --in "$W/$X" --out "$W/$tag.aet" --threads "$T" >/dev/null 2>&1 || { log "$tag: encode failed"; return 1; }
    ./aceapex d --in "$W/$tag.aet" --out "$W/$tag.rt" >/dev/null 2>&1 && cmp -s "$W/$tag.rt" "$W/$X" && rm -f "$W/$tag.rt" || { log "$tag: round trip FAILED"; return 1; }
    log "$tag: $(stat -c%s "$W/$tag.aet") B (CPU round trip ok)"; }
mk t2t.fa t2t.open "" open || exit 4; mk hg00438.fa hg00438.open "" open || exit 4; mk hg00621.fa hg00621.bs16k 16384 open || exit 4; mk t2t.fa t2t.def "" "" || exit 4
log "t2t.open must equal the table's archive: 830777231 B; hg00438.open: 758943628 B (GPU-A1 small block)"
st=0
# 5. B16
log "== B16 gpu_a1 hg00621 (block 16 KiB)"
"$W/gpu_a1" "$W/hg00621.bs16k.aet=ace16k" "$W/hg00621.fa" - 10000 16384 20 "$T" 2>&1 | tee -a "$L"; [ "${PIPESTATUS[0]}" = 0 ] || st=5
# 6. HYBRID-1
for X in t2t hg00438; do log "== HYBRID-1 $X"; "$W/hybrid1" hybrid "$X" "$W/$X.open.aet" "$W/$X.fa" "$T" 5 256 2>&1 | tee -a "$L"; [ "${PIPESTATUS[0]}" = 0 ] || st=5; done
[ "$st" = 0 ] || { log "KILL before FULLPOD-1"; exit 5; }
# 7. FULLPOD-1: loggers once a second; every job alone (FP_BASE s), then all together (FP_ALL s)
H=$((T / 2))
mon() { local tag=$1
    nvidia-smi dmon -s pucm -d 1 -o T > "$R/fp_${tag}_dmon.log" 2>&1 & echo $! > "$R/.mon1"
    ( p=$(awk '/usage_usec/{print $2}' /sys/fs/cgroup/cpu.stat); while sleep 1; do q=$(awk '/usage_usec/{print $2}' /sys/fs/cgroup/cpu.stat)
        echo "$(date -u +%T) pod_cpu_pct $(awk -v a=$p -v b=$q -v t=$T 'BEGIN{printf "%.1f", (b-a)/1e4/t}')"; p=$q; done ) > "$R/fp_${tag}_cpu.log" 2>&1 & echo $! > "$R/.mon2"
    mpstat 1 > "$R/fp_${tag}_mpstat_host.log" 2>&1 & echo $! > "$R/.mon3"; }
unmon() { kill $(cat "$R/.mon1" "$R/.mon2" "$R/.mon3") 2>/dev/null; }
GPUJ="$W/hybrid1 fullgpu $W/t2t.open.aet $W/t2t.fa"; COMPJ="$W/hybrid1 cpucomp $H"; DECJ="$W/hybrid1 cpudec $H"
CF="$W/t2t.fa $W/enwik9 $W/silesia.ref.tar"
log "== FULLPOD-1 base ($FP_BASE s each, $H threads per CPU job)"
mon base_gpu;  $GPUJ "$FP_BASE" > "$R/fp_base_gpu.log" 2>&1 || st=5; unmon
mon base_comp; $COMPJ "$FP_BASE" $CF > "$R/fp_base_comp.log" 2>&1 || st=5; unmon
mon base_dec;  $DECJ "$FP_BASE" "$W/t2t.def.aet" "$W/t2t.fa" > "$R/fp_base_dec.log" 2>&1 || st=5; unmon
grep -h FPEND "$R"/fp_base_*.log | tee -a "$L"; [ "$st" = 0 ] || { log "KILL in FULLPOD-1 base"; exit 5; }
log "== FULLPOD-1 all together ($FP_ALL s)"
mon all; $COMPJ "$FP_ALL" $CF > "$R/fp_all_comp.log" 2>&1 & PC=$!
until grep -c roundtrip "$R/fp_all_comp.log" 2>/dev/null | grep -q 3; do sleep 1; kill -0 $PC 2>/dev/null || break; done   # its round trips done: its timer runs
log "together window starts $(date -u +%T)"
$GPUJ "$FP_ALL" > "$R/fp_all_gpu.log" 2>&1 & PG=$!; $DECJ "$FP_ALL" "$W/t2t.def.aet" "$W/t2t.fa" > "$R/fp_all_dec.log" 2>&1 & PD=$!
wait $PG || st=5; wait $PD || st=5; wait $PC || st=5; unmon
grep -h FPEND "$R"/fp_all_*.log | tee -a "$L"
nvidia-smi --query-gpu=name,clocks.sm,clocks.mem,temperature.gpu,power.draw --format=csv | tee -a "$L"
exit $st
