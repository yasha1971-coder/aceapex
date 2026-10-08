#!/usr/bin/env bash
# run_cpu.sh - the CPU part of research/refrel as run on ace-core (2026-10-03): build the tool, encode the HPRC
# assemblies against T2T, compress the two streams and the open archive with the CLI, full decode == FASTA, window
# curves (refrel and open, 1 and 16 threads), AGC with T2T as the first sample. Logs: research/refrel/logs/.
# Usage: research/refrel/run_cpu.sh <t2t.fa> <work_dir> <asm.fa>...      (run from the repository root, CLI built: make)
set -Eeuo pipefail
REFFA=$1; WD=$2; shift 2; ASMS=("$@"); T=$(nproc)
mkdir -p $WD
g++ -std=c++17 -O3 -march=native -funroll-loops -Isrc -o $WD/refrel research/refrel/refrel.cpp src/aceapex_api.cpp -lzstd -lpthread
/usr/bin/time -f "wall %e s, peak RSS %M KB" $WD/refrel build $REFFA $WD $T "${ASMS[@]}" | tee $WD/build.log
E="env -i PATH=$PATH ACEAPEX_BS=16384 LIT_CHUNK=65536 AX_PROFILE=open ./aceapex c"
for a in "${ASMS[@]}"; do n=$(basename $a .fa)
  $E --in $WD/$n.tok --out $WD/$n.tok.aet --threads $T >/dev/null; $E --in $WD/$n.lit --out $WD/$n.lit.aet --threads $T >/dev/null
  $E --in $a --out $WD/$n.open.aet --threads $T >/dev/null
  echo "RRSIZE $n tok $(stat -c%s $WD/$n.tok.aet) lit $(stat -c%s $WD/$n.lit.aet) meta $(stat -c%s $WD/$n.meta.zst) open $(stat -c%s $WD/$n.open.aet)" | tee -a $WD/sizes.log
  $WD/refrel full $REFFA $WD/$n $WD/rt.fa; cmp $WD/rt.fa $a; rm -f $WD/rt.fa; echo "$n full == FASTA" | tee -a $WD/full.log
done
n0=$(basename ${ASMS[0]} .fa)
for th in 1 $T; do $WD/refrel windows $REFFA $WD/$n0 ${ASMS[0]} $WD/$n0.open.aet $th; done | tee $WD/windows.log
if [ -n "${AGC:-}" ]; then
  $AGC create -t $T -o $WD/t2t.agc $REFFA >/dev/null 2>&1; $AGC create -t $T -o $WD/t2t_all.agc $REFFA "${ASMS[@]}" >/dev/null 2>&1
  echo "AGC t2t $(stat -c%s $WD/t2t.agc) B, t2t + ${#ASMS[@]} assemblies $(stat -c%s $WD/t2t_all.agc) B" | tee $WD/agc.log
fi
