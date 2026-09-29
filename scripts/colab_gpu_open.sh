#!/usr/bin/env bash
# Colab (or any CUDA host): the open profile on the GPU (ADR-019) - chr1 decoded without a
# zstd frame - against the zstd default and the rANS token profile. One Colab cell:
#   !rm -rf /content/aceapex && git clone -q -b main https://github.com/yasha1971-coder/aceapex /content/aceapex && bash /content/aceapex/scripts/colab_gpu_open.sh
# Steps: provenance, libzstd + nvCOMP (pip nvidia-nvcomp-cu12; the open archive makes no nvCOMP
# call, the other two need it), CLI + aceapex_gpu build, both warp-step emulators, the open
# conformance fixtures on the GPU, chr1 (hg38, md5 pinned) in three archives with the T4
# profile of 2026-09-28 (16 KiB blocks, 64 KiB literal chunks):
#   zstd   FSE_CHUNK=4096       tokens and literals in zstd frames (nvCOMP)
#   rans   AX_TOK=rans          tokens rANS (k_rans), literals zstd (ADR-018)
#   open   AX_PROFILE=open      tokens rANS, literals open DNA pack / open plain (ADR-019)
# CPU round-trip of each archive, aceapex_gpu on each, then two tables: stages, and the parts
# of lit (per piece class) and unpack (per kernel).
set -uo pipefail
cd "$(dirname "$0")/.."; D=$(date -u +%Y-%m-%d); L=results/colab-$D-gpu-open.log; mkdir -p results
W=${WORK:-/content/work}; mkdir -p $W; C=$W/chr1.fa
{ echo "== provenance $D"; nvidia-smi -L; nvidia-smi --query-gpu=driver_version,clocks.max.sm --format=csv,noheader
  nvcc --version | tail -1; g++ --version | head -1; git rev-parse --short HEAD; nproc; } 2>&1 | tee $L
[ -f /usr/include/zstd.h ] || { apt-get -qq update && apt-get -qq install -y libzstd-dev >/dev/null; }
grep -h '#define ZSTD_VERSION_\(MAJOR\|MINOR\|RELEASE\)' /usr/include/zstd.h | awk '{print $3}' | paste -sd. - | sed 's/^/libzstd /' | tee -a $L
pip -q install nvidia-nvcomp-cu12 2>&1 | tail -1
NV=$(dirname "$(dirname "$(find / -name libnvcomp.so.5 -path '*libnvcomp/lib64*' 2>/dev/null | head -n 1)")")
[ -f "$NV/include/nvcomp/zstd.h" ] || { echo "nvCOMP not found" | tee -a $L; exit 1; }
pip show nvidia-nvcomp-cu12 2>/dev/null | grep -i '^version' | sed 's/^/nvcomp /' | tee -a $L
export LD_LIBRARY_PATH=$NV/lib64:${LD_LIBRARY_PATH:-}
SM=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n 1 | tr -d '.')
make -s 2>&1 | grep -i error; [ -x ./aceapex ] || { echo "no CLI" | tee -a $L; exit 1; }
if nvcc -O3 -arch=sm_$SM -I$NV/include -L$NV/lib64 -l:libnvcomp.so.5 -o $W/aceapex_gpu aceapex_gpu.cu 2>$W/nvcc.err; then
  echo "built aceapex_gpu sm_$SM" | tee -a $L
else echo "BUILD FAILED aceapex_gpu" | tee -a $L; cat $W/nvcc.err; exit 1; fi
for e in rans_warp_emu open_warp_emu; do
  g++ -std=c++17 -O2 -Isrc -o $W/$e scripts/$e.cpp && $W/$e verify/fixtures/conf/*.aet | tee -a $L; done

# the open conformance fixtures on the GPU (inputs regenerated from their seeds)
python3 scripts/make_fixtures.py --regen >/dev/null
FX="dna_open_2MiB dna_open_mixed_300K dna_open_4097B dna_openlit_300K text_open_200K"
for f in $FX; do
  r=$($W/aceapex_gpu verify/fixtures/conf/$f.aet /tmp/conf_inputs/$f auto 3 1 2>&1); rc=$?
  echo "fixture $f on the GPU: exit $rc, $(echo "$r" | grep -c 'MATCHES OK') MATCHES OK, $(echo "$r" | grep -c 'DIFFERS X') DIFFERS" | tee -a $L
done

[ -s $C ] || curl -sL https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/chr1.fa.gz | gunzip -c > $C
echo "9465e0f0df6e2c6eb39729c39cee5465  $C" | md5sum -c - | tee -a $L || exit 1
T=$(nproc)
for P in zstd rans open; do
  case $P in zstd) E="FSE_CHUNK=4096";; rans) E="AX_TOK=rans";; open) E="AX_PROFILE=open";; esac
  A=$W/chr1.$P.aet
  env -i PATH=$PATH ACEAPEX_BS=16384 LIT_CHUNK=65536 $E ./aceapex c --in $C --out $A --threads $T >/dev/null 2>&1
  env -i PATH=$PATH ./aceapex d --in $A --out $W/rt.bin >/dev/null 2>&1
  cmp -s $W/rt.bin $C && echo "$P ($E): archive $(stat -c%s $A) B, CPU round-trip bit-perfect" | tee -a $L \
    || { echo "$P: CPU ROUND-TRIP FAILED" | tee -a $L; exit 1; }
  rm -f $W/rt.bin
done
for P in zstd rans open; do
  echo "== aceapex_gpu $P" | tee -a $L
  $W/aceapex_gpu $W/chr1.$P.aet $C auto 7 4 2>&1 | tee -a $L; echo "exit ${PIPESTATUS[0]}" | tee -a $L
done
G=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1)
echo; echo "chr1 on $G, ms, median of 7" | tee -a $L
{ printf 'archive\tbytes\ttokens\tliterals\ttok\tlit\tunpack\tmatch\ton-device\t+H2D\tGB/s\tcheck\n'
  grep '^ROW' $L | cut -f2-13 | sed "s#$W/##"; } | column -t -s $'\t' | tee $L.t1
echo; echo "parts, ms: lit = zstd frames + pieces by class; unpack = zstd-pack kernels + open kernels" | tee -a $L.t1
{ printf 'archive\tlit.zstd\tseq\tcse\tgap\tval\tplain\tun.zstdpack\tbases\tcase\texceptions\n'
  grep '^ROW' $L | awk -F'\t' -v OFS='\t' '{print $2,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23}' | sed "s#$W/##"; } | column -t -s $'\t' | tee -a $L.t1
cat $L.t1 >> $L; rm -f $L.t1
# verdict from the lines each tool prints for a failure: 3 bit-perfect rows, 3 exits 0, both
# emulators pass, 5 fixtures exit 0 with 3 MATCHES OK each, no FNV mismatch, nothing rejected
N=$(awk -F'\t' '$1=="ROW" && $13=="bit-perfect"' $L | wc -l); X=$(grep -c '^exit 0$' $L)
E=$(grep -c $'^head_\(rans\|open\)_warp_emu\tpass' $L); F=$(grep -c '^fixture .*: exit 0, 3 MATCHES OK, 0 DIFFERS$' $L)
echo "bit-perfect rows $N/3, exits 0 $X/3, emulators $E/2, fixtures $F/5" | tee -a $L
[ "$N" = 3 ] && [ "$X" = 3 ] && [ "$E" = 2 ] && [ "$F" = 5 ] && ! grep -q 'DIFFERS X\|archive rejected\|MISMATCH' $L \
  && echo "RESULT: all passes bit-perfect on the GPU" | tee -a $L \
  || { echo "!!! NOT PASSED - no figure from this run is valid" | tee -a $L; exit 1; }
