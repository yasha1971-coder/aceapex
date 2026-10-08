#!/usr/bin/env bash
# run_colab_r3.sh - refrel3 on the GPU, Colab RTX PRO 6000 Blackwell (sm_120), staged, fail-fast. Clones ACEAPEX (branch
# refrel), takes T2T and four HPRC year-1 haplotypes (HG00438.1/.2, HG00621.1/.2) from the Drive store gpu_run.sh uses
# (MyDrive/aceapex_corpus: t2t.fa[.gz], hprc/<name>.fa.gz) or fetches them (T2T: NCBI, md5; HPRC: S3, sha256 of the
# year-1 index), encodes refrel3 on the VM, then:
#   for RR_BS = 16384 / 4096 / 2048 / 1024 (block = entropy unit; the format is not frozen - this picks it):
#   S0 build: nvcc -arch=native -lineinfo -Xptxas -v (registers / smem / spills per kernel), --Werror all-warnings where
#      it compiles (else the warnings are listed and the build is repeated without it); host objects and link separately
#   S1 correctness: full decode of HG00438.1 on the card by both kernels (FASTA rebuilt, XXH3 == the file's); 100 000
#      windows W = 256 B .. 1 MiB over the four assemblies, classic and queue kernel each == the CPU refrel3 decode
#   curves: per W the speed of light (windows cut from the raw bases resident), the classic kernel (128 threads, decode
#      then copies) and the queue kernel (one warp: lane 0 decodes, lanes 1..31 copy as ops come), share of the ceiling;
#      occupancy; queue kernel over windows per batch 1k..256k
#   D_Q: full decode rate per block size (both kernels, best of 3); window_law.py: windows/s ~ D_Q / (W + Q - 1) against
#      the measured, and Q* = argmax subject to r(Q) <= r_target (size relative to Q = 16384)
#   once: S2 D2D memcpy GB/s; S3 classic kernel grid (threads per block) + clock64 decode/copy split; ncu sections of both
#      kernels (RR_BS 16384 and 4096, W 4 KiB) if ncu runs here
# Result: MyDrive/aceapex_logs/refrel3_gpu_<date>.txt; any failure: ..._FAILED.txt with the stage, line and command.
# Env: REF (git ref, default refrel), DRIVE, W
set -Eeuo pipefail
shopt -s nullglob
REF=${REF:-refrel}
DRIVE=${DRIVE:-/content/drive/MyDrive}
STORE=$DRIVE/aceapex_corpus; LOGS=$DRIVE/aceapex_logs
W=${W:-/content/refrel3}; SRC=$W/aceapex; D=$W/rr; B=$W/bin
NAMES=(HG00438.1 HG00438.2 HG00621.1 HG00621.2)
[ -d $DRIVE ] || { echo "Drive not mounted: from google.colab import drive; drive.mount('/content/drive')"; exit 1; }
mkdir -p $W $D $B $STORE/hprc $LOGS
DAY=$(date -u +%Y-%m-%d); RUNLOG=$W/run-$DAY.log; OUT=$LOGS/refrel3_gpu_$DAY.txt; STAGE=setup
exec > >(tee -a $RUNLOG) 2>&1
on_err() { local rc=$? ln=$1 cmd=$2
  echo "FAILED in $STAGE: exit $rc at line $ln: $cmd"
  { echo "# refrel3_gpu FAILED $(date -u +%FT%TZ) in stage $STAGE: exit $rc at line $ln: $cmd"; tail -n 100 $RUNLOG; } > $LOGS/refrel3_gpu_${DAY}_FAILED.txt 2>/dev/null || true
  echo "details: $LOGS/refrel3_gpu_${DAY}_FAILED.txt"; echo "DONE — выключи runtime"; }
trap 'on_err $LINENO "$BASH_COMMAND"' ERR
T=$(nproc)
nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader | tee $W/gpu.txt
command -v nvcc >/dev/null || export PATH=/usr/local/cuda/bin:$PATH
nvcc --version | tail -n 2 | tee -a $W/gpu.txt

# ---------------------------------------------------------------- code and data
if [ -d $SRC/.git ]; then git -C $SRC fetch -q origin $REF; git -C $SRC checkout -q FETCH_HEAD; else git clone -q https://github.com/yasha1971-coder/aceapex.git $SRC; git -C $SRC checkout -q $REF; fi
COMMIT=$(git -C $SRC rev-parse HEAD); echo "aceapex $COMMIT ($REF)"
FA=$W/t2t.fa
if [ ! -s $FA ]; then
  if [ -s $STORE/t2t.fa ]; then cp $STORE/t2t.fa $FA
  elif [ -s $STORE/t2t.fa.gz ]; then gunzip -c $STORE/t2t.fa.gz > $FA
  else curl -fsSL --retry 3 -o $W/t2t.fa.gz https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/009/914/755/GCA_009914755.4_T2T-CHM13v2.0/GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz
    gunzip -c $W/t2t.fa.gz > $FA; cp $W/t2t.fa.gz $STORE/t2t.fa.gz; rm -f $W/t2t.fa.gz; fi
fi
echo "cd1e52ce400c027ed0b7ab4b9d613f5a  $FA" | md5sum -c -
HD=$STORE/hprc; IDX=$HD/index.tsv
[ -s $IDX ] || curl -fsSL --retry 3 -o $IDX https://raw.githubusercontent.com/human-pangenomics/HPP_Year1_Assemblies/main/assembly_index/Year1_assemblies_v2_genbank.index
for nm in "${NAMES[@]}"; do
  smp=${nm%.*}; hap=${nm##*.}
  read -r url sha < <(awk -F'\t' -v s=$smp -v h=$hap '$1==s{ if (h==1) print $2, $6; else print $3, $7 }' $IDX)
  [ -n "$url" ] || { echo "$nm not in the year-1 index"; false; }
  u=${url/s3:\/\/human-pangenomics/https:\/\/s3-us-west-2.amazonaws.com\/human-pangenomics}
  if [ ! -s $HD/$nm.fa.gz ]; then curl -fsSL --retry 3 -o $HD/$nm.fa.gz.part "$u"; mv $HD/$nm.fa.gz.part $HD/$nm.fa.gz; fi
  [ "$(sha256sum $HD/$nm.fa.gz | cut -d' ' -f1)" = "$sha" ] || { echo "$nm: sha256 mismatch"; false; }
  [ -s $D/$nm.fa ] || gunzip -c $HD/$nm.fa.gz > $D/$nm.fa
done
echo "HPRC: ${NAMES[*]} (sha256 == the year-1 index)"

# ---------------------------------------------------------------- S0 build
STAGE=S0; cd $SRC
INC="-Isrc -Iresearch/refrel"
g++ -std=c++17 -O3 -march=native -c -o $B/aceapex_api.o src/aceapex_api.cpp
gpu_build() { # <tag> <extra flags> -> $B/refrel3_gpu<tag>; ptxas report in $W/ptxas<tag>.txt
  local tag=$1; shift
  if nvcc -std=c++17 -O3 -arch=native -lineinfo -Xptxas -v --Werror all-warnings "$@" $INC -c -o $B/r3gpu$tag.o research/refrel/refrel3_gpu.cu > $W/ptxas$tag.txt 2>&1; then echo "S0$tag: compiled with --Werror all-warnings"
  else echo "S0$tag: --Werror all-warnings failed - warnings / errors:"; grep -E "warning|error" $W/ptxas$tag.txt | head -40
       nvcc -std=c++17 -O3 -arch=native -lineinfo -Xptxas -v "$@" $INC -c -o $B/r3gpu$tag.o research/refrel/refrel3_gpu.cu > $W/ptxas$tag.txt 2>&1 || { tail -40 $W/ptxas$tag.txt; false; }
       echo "S0$tag: compiled without --Werror (warnings above)"; fi
  nvcc -arch=native -o $B/refrel3_gpu$tag $B/r3gpu$tag.o $B/aceapex_api.o -lzstd -lpthread
  grep -E "Compiling entry function|Used [0-9]+ registers|spill" $W/ptxas$tag.txt | sed 's/^ptxas info *: *//' | head -24 > $W/ptxas$tag.short.txt || true; }
BSS=(16384 4096 2048 1024)
for bs in "${BSS[@]}"; do
  g++ -std=c++17 -O3 -march=native -funroll-loops -DRR_BS=${bs}u $INC -o $B/refrel3_$bs research/refrel/refrel3.cpp src/aceapex_api.cpp -lzstd -lpthread
  gpu_build _$bs -DRR_BS=${bs}u
  cat $W/ptxas_$bs.short.txt
done
cd $W

# ---------------------------------------------------------------- per block size: encode, S1, curves
FAS=(); for nm in "${NAMES[@]}"; do FAS+=($D/$nm.fa); done
for bs in "${BSS[@]}"; do
  STAGE="S1 RR_BS=$bs"; DB=$D/bs$bs; mkdir -p $DB
  $B/refrel3_$bs build $FA $DB $T "${FAS[@]}" > $W/build_$bs.txt
  for nm in "${NAMES[@]}"; do echo "R3SIZE $bs $nm $(( $(stat -c%s $DB/$nm.r3) + $(stat -c%s $DB/$nm.meta3.zst) ))" | tee -a $W/build_$bs.txt; done
  ARGS=(); for i in 0 1 2 3; do ARGS+=($DB/${NAMES[$i]} ${FAS[$i]}); done
  $B/refrel3_gpu_$bs s1 $FA "${ARGS[@]}" | tee $W/s1_$bs.txt
  grep -q "S1RESULT.*ok" $W/s1_$bs.txt
  STAGE="curves RR_BS=$bs"
  $B/refrel3_gpu_$bs curves $FA $DB/${NAMES[0]} ${FAS[0]} | tee $W/curves_$bs.txt
  ! grep -q FAILED $W/curves_$bs.txt
done

# ---------------------------------------------------------------- once: S2, S3, ncu
STAGE=S2
$B/refrel3_gpu_16384 s2 $FA $D/bs16384/${NAMES[0]} ${FAS[0]} | tee $W/s2.txt
! grep -q FAILED $W/s2.txt
STAGE=S3
$B/refrel3_gpu_16384 s3 $FA $D/bs16384/${NAMES[0]} ${FAS[0]} | tee $W/s3.txt
NCU=$(command -v ncu || ls /usr/local/cuda/bin/ncu 2>/dev/null || true)
if [ -n "$NCU" ]; then
  for bs in 16384 4096; do for kern in 128 0; do f=$W/ncu_${bs}_$kern.txt
    $NCU --section SpeedOfLight --section Occupancy --section WarpStateStats -k regex:'r3_kernel|r3q_kernel' --launch-count 1 $B/refrel3_gpu_$bs one $FA $D/bs$bs/${NAMES[0]} 4096 65536 $kern > $f 2>&1 || echo "ncu exit $?" >> $f
  done; done
else echo "ncu not found" > $W/ncu_16384_128.txt; fi

# ---------------------------------------------------------------- tables
STAGE=report
{ echo "# refrel3 on the GPU - $(head -n 1 $W/gpu.txt); aceapex $COMMIT; $(date -u +%FT%TZ); $T host threads"
  echo; echo "## S0 build"; grep -h "^S0" $RUNLOG | sort -u
  for bs in "${BSS[@]}"; do echo "ptxas RR_BS=$bs:"; cat $W/ptxas_$bs.short.txt; done
  echo; echo "## size per assembly (r3 + meta3, bytes) by RR_BS"; for bs in "${BSS[@]}"; do grep -h "^R3SIZE" $W/build_$bs.txt; done
  echo; echo "## S1 correctness"; for bs in "${BSS[@]}"; do echo "RR_BS=$bs:"; grep -E "^S1" $W/s1_$bs.txt; done
  echo; echo "## curves: speed of light / classic / queue, occupancy"; for bs in "${BSS[@]}"; do grep -hE "^OCC|^CURVE" $W/curves_$bs.txt; done
  echo; echo "## D_Q full decode per block size"; for bs in "${BSS[@]}"; do grep -h "^FULLQ" $W/curves_$bs.txt; done
  echo; echo "## queue kernel by windows per batch"; for bs in "${BSS[@]}"; do grep -h "^QGRID" $W/curves_$bs.txt; done
  echo; echo "## window law and the block-size choice (window_law.py)"; python3 $SRC/research/refrel/window_law.py $W
  echo; echo "## S2 (RR_BS 16384)"; grep -E "^S2" $W/s2.txt
  echo; echo "## S3 classic kernel (RR_BS 16384)"; grep -E "^S3|^\[s3\]" $W/s3.txt
  echo; echo "## ncu (W 4 KiB, 65 536 windows; 128 = classic, 0 = queue)"; for f in $W/ncu_*.txt; do echo "--- $(basename $f)"; grep -E "Duration|Throughput|Occupancy|Achieved|Registers|Shared Memory|Stall|stall|Warp Cycles|Issue|ERR|Error|not found|exit" $f | head -40; done
} > $OUT
echo "written: $OUT"
echo "DONE — выключи runtime"
