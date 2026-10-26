#!/usr/bin/env bash
# #NZ6: the zstd frame of this directory (good.zst, 1136 B) and its corrupt copy (bad.zst: offset 291, 0x3f -> 0xc6)
# through nvCOMP 6.0.0.12 batched zstd, batch of 1, 60 s watchdog (repro6.cu). First log line: nvidia-smi.
set -uo pipefail
cd "$(dirname "$0")"; L=nz6-$(date -u +%Y-%m-%d).log
nvidia-smi --query-gpu=name,memory.total,clocks.max.sm,driver_version --format=csv,noheader > $L 2>&1
{ nvcc --version | tail -1; sha256sum good.zst bad.zst; cmp -l good.zst bad.zst; } >> $L 2>&1
CU=$(nvcc --version | sed -n 's/.*release \([0-9]*\)\..*/\1/p'); PK=nvidia-libnvcomp-cu$CU
pip -q install "$PK==6.0.0.12" 2>&1 | tail -1
NV=$(dirname "$(dirname "$(find / -name zstd.h -path '*libnvcomp/include/nvcomp/zstd.h' 2>/dev/null | head -n 1)")"); NV=${NV%/include}
LIB=$(ls -d $NV/lib64 $NV/lib 2>/dev/null | head -n 1); export LD_LIBRARY_PATH=$LIB:${LD_LIBRARY_PATH:-}
echo "nvcomp: $PK $(pip show $PK 2>/dev/null | sed -n 's/^Version: //p') at $NV" >> $L
SM=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n 1 | tr -d '.')
nvcc -O2 -arch=sm_$SM -I$NV/include -L$LIB -o repro6 repro6.cu -l:libnvcomp.so.6 >> $L 2>&1 || { echo "build failed" >> $L; cat $L; exit 1; }
for f in good.zst bad.zst; do
  echo "== $f" >> $L
  s=$(date +%s.%N); timeout 75 ./repro6 $f >> $L 2>&1; rc=$?; e=$(date +%s.%N)
  echo "exit $rc, wall $(echo "$e - $s" | bc) s" >> $L
done
cat $L
