#!/usr/bin/env bash
# run_colab_gpu_d2d.sh - C1 (a) GPU_D2D_SILESIA: device-to-device decode GB/s on silesia.tar and enwik9 for ACEAPEX 2.2.2
# (open profile, level 3 = the l1 encoder) against nvCOMP batched LZ4 / Zstd / GDeflate / ANS, and StreamLZ if its binary
# is provided. Every row: archive size, ratio, decode on the device timed with CUDA events (median of 9 after 3
# warm-ups), output == the original (byte compare / SHA-256), and separately the H2D copy of the archive (pinned, CUDA
# events, median of 9) and the whole path H2D + decode. One row per codec at an equal block of 64 KiB (ACEAPEX_BS=65536,
# nvCOMP uncomp_chunk_size=65536); ACEAPEX also at its default block.
# Data (Drive store MyDrive/aceapex_corpus, else fetched): silesia.tar (211 957 760 B), enwik9 (1 000 000 000 B); SHA-256
# printed. StreamLZ: MyDrive/aceapex_corpus/streamlz/<binary> (from encode.su; not fetched here) - if absent or not runnable
# on this GPU, its row says "not run" with the reason.
# Log: MyDrive/aceapex_logs/gpu_d2d_<date>.txt; failure: ..._FAILED.txt with the stage.
set -Eeuo pipefail
ulimit -c 0
DRIVE=${DRIVE:-/content/drive/MyDrive}; STORE=$DRIVE/aceapex_corpus; LOGS=$DRIVE/aceapex_logs
W=${W:-/content/gpu_d2d}; SRC=$W/aceapex; TAG=${TAG:-v2.2.2}; HERE=$(cd "$(dirname "$0")" && pwd)
[ -d $DRIVE ] || { echo "Drive not mounted"; echo "DONE — выключи runtime"; exit 1; }
mkdir -p $W $LOGS; DAY=$(date -u +%Y-%m-%d); RUNLOG=$W/run.log; OUT=$LOGS/gpu_d2d_$DAY.txt; STAGE=setup
exec > >(tee -a $RUNLOG) 2>&1
on_err(){ local rc=$? ln=$1 cmd=$2; echo "FAILED in $STAGE: exit $rc at line $ln: $cmd"
  { echo "# gpu_d2d FAILED $(date -u +%FT%TZ) in $STAGE: exit $rc at line $ln: $cmd"; tail -n 120 $RUNLOG; } > $LOGS/gpu_d2d_${DAY}_FAILED.txt 2>/dev/null || true
  echo "DONE — выключи runtime"; }
trap 'on_err $LINENO "$BASH_COMMAND"' ERR
nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader | tee $W/env.txt
command -v nvcc >/dev/null || export PATH=/usr/local/cuda/bin:$PATH
nvcc --version | tail -1 | tee -a $W/env.txt
[ -f /usr/include/zstd.h ] || { apt-get -qq update && apt-get -qq install -y libzstd-dev >/dev/null; }

STAGE=data
f_get(){ local name=$1 url=$2; if [ -s $STORE/$name ]; then cp $STORE/$name $W/$name; else curl -fsSL --retry 3 -o $W/$name.zip "$url"; (cd $W && unzip -o -q $name.zip && rm -f $name.zip); fi; }
[ -s $W/enwik9 ] || f_get enwik9 http://mattmahoney.net/dc/enwik9.zip
[ -s $W/silesia.tar ] || { [ -s $STORE/silesia.tar ] && cp $STORE/silesia.tar $W/silesia.tar; }
[ -s $W/silesia.tar ] || { echo "silesia.tar not in $STORE (upload the corpus tar: 211 957 760 B)"; false; }
[ "$(stat -c%s $W/silesia.tar)" = 211957760 ] && [ "$(stat -c%s $W/enwik9)" = 1000000000 ]
(cd $W && sha256sum silesia.tar enwik9) | tee -a $W/env.txt

STAGE=build
[ -d $SRC/.git ] || git clone -q https://github.com/yasha1971-coder/aceapex.git $SRC
git -C $SRC checkout -q $TAG; echo "aceapex $TAG $(git -C $SRC rev-parse HEAD)" | tee -a $W/env.txt
pip -q install nvidia-nvcomp-cu12 2>&1 | grep -v 'requires\|incompatible' | tail -1 || true
NV=$(dirname "$(dirname "$(find / -name libnvcomp.so.5 -path '*libnvcomp/lib64*' 2>/dev/null | head -n 1)")")
pip show nvidia-nvcomp-cu12 | grep -i '^version' | sed 's/^/nvcomp /' | tee -a $W/env.txt
export LD_LIBRARY_PATH=$NV/lib64:${LD_LIBRARY_PATH:-}
SM=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n 1 | tr -d '.')
cd $SRC && make -s && [ -x ./aceapex ]
nvcc -std=c++17 -O3 -arch=sm_$SM -DACEAPEX_ENV_TUNING -Isrc -DACEAPEX_GPU_NVCOMP -I$NV/include -L$NV/lib64 -l:libnvcomp.so.5 \
  -o $W/gpu_api_test scripts/gpu_api_test.cu src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp -lzstd
cat > $W/h2d.cu <<'EOF'
// h2d <file> <reps>: pinned host -> device copy of the file, CUDA events, median of reps after 3 warm-ups (ms)
#include <cstdio>
#include <vector>
#include <algorithm>
#include <cuda_runtime.h>
int main(int c, char** v) { FILE* f = fopen(v[1], "rb"); fseek(f, 0, SEEK_END); size_t n = ftell(f); fseek(f, 0, SEEK_SET);
  void* h; cudaMallocHost(&h, n); if (fread(h, 1, n, f) != n) return 2; fclose(f); void* d; cudaMalloc(&d, n);
  cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b); int R = atoi(v[2]); std::vector<float> t;
  for (int i = 0; i < R + 3; i++) { cudaEventRecord(a); cudaMemcpy(d, h, n, cudaMemcpyHostToDevice); cudaEventRecord(b); cudaEventSynchronize(b); float ms; cudaEventElapsedTime(&ms, a, b); if (i >= 3) t.push_back(ms); }
  std::sort(t.begin(), t.end()); printf("H2D\t%s\t%zu\t%.3f\n", v[1], n, t[t.size() / 2]); return 0; }
EOF
nvcc -O3 -arch=sm_$SM -o $W/h2d $W/h2d.cu

STAGE=aceapex
for X in silesia.tar enwik9; do
  for cfg in "default:" "bs64k:ACEAPEX_BS=65536"; do name=${cfg%%:*}; e=${cfg#*:}
    env -i PATH=$PATH AX_PROFILE=open $e ./aceapex c --in $W/$X --out $W/$X.$name.aet --level 3 >/dev/null
    echo "ACE_SIZE $X $name $(stat -c%s $W/$X.$name.aet)"
    $W/gpu_api_test $W/$X.$name.aet $W/$X 9 0 0 > $W/api_$X.$name.txt 2>&1 || true
    grep -E "full decode on-device|full decode: return|^APIROW" $W/api_$X.$name.txt
    $W/h2d $W/$X.$name.aet 9
  done
done

STAGE=nvcomp
# nvCOMP through its C++ batched API only (no Python wrapper in the timed path): nvc_bench.cu next to this script
nvcc -std=c++17 -O3 -arch=sm_$SM -I$NV/include -L$NV/lib64 -l:libnvcomp.so.5 -o $W/nvc_bench "$HERE/nvc_bench.cu"
for X in silesia.tar enwik9; do for a in lz4 zstd gdeflate ans; do
  $W/nvc_bench $W/$X $a 65536 || echo "NVROW	$W/$X	$a	not run or failed (exit $?)"; done; done | tee $W/nvcomp.txt

STAGE=streamlz
SLZ=$(ls $STORE/streamlz/* 2>/dev/null | head -1 || true)
if [ -z "$SLZ" ]; then echo "STREAMLZ not run: no binary in $STORE/streamlz (encode.su release to be uploaded by hand)" | tee $W/streamlz.txt
else echo "STREAMLZ binary $SLZ: $( (file "$SLZ"; "$SLZ" --help 2>&1 | head -3) | tr '\n' ' ')" | tee $W/streamlz.txt
     echo "STREAMLZ not run: interface to be wired after the binary is inspected (no guessing of its options)" | tee -a $W/streamlz.txt; fi

STAGE=report
{ echo "# GPU d2d decode - $(head -1 $W/env.txt); $(date -u +%FT%TZ)"; sed -n '2,$p' $W/env.txt
  echo; echo "## ACEAPEX ${TAG} open, level 3 (gpu_api_test: full decode on device, CUDA events, median of 9)"; grep -h -E "^ACE_SIZE|full decode on-device|full decode: return|^H2D" $RUNLOG
  echo; echo "## nvCOMP"; cat $W/nvcomp.txt
  echo; echo "## StreamLZ"; cat $W/streamlz.txt; } > $OUT
echo "written: $OUT"
echo "DONE — выключи runtime"
