#!/usr/bin/env bash
# run_colab_r3.sh - refrel3 on the GPU, Colab RTX PRO 6000 Blackwell (sm_120), staged, fail-fast. Clones ACEAPEX (branch
# refrel), takes T2T and four HPRC year-1 haplotypes (HG00438.1/.2, HG00621.1/.2) from the Drive store gpu_run.sh uses
# (MyDrive/aceapex_corpus: t2t.fa[.gz], hprc/<name>.fa.gz) or fetches them (T2T: NCBI, md5; HPRC: S3, sha256 of the
# year-1 index), encodes refrel3 on the VM, then:
#   S0 build: nvcc -arch=native -lineinfo -Xptxas -v (registers / smem / spills per kernel), --Werror all-warnings where
#      it compiles (else the warnings are listed and the build is repeated without it); host objects and link separately
#   S1 correctness: full decode of HG00438.1 on the card (FASTA rebuilt, XXH3 == the file's); 100 000 windows W = 256 B ..
#      1 MiB over the four assemblies, each == the CPU refrel3 decode
#   S2 ceiling: the same windows cut from the raw bases resident (speed of light); D2D memcpy GB/s
#   S3 throttling: windows/s by W; windows per batch 1k..256k x threads per block 32..256; clock64 split decode / copies;
#      occupancy; ncu sections (SpeedOfLight, Occupancy, WarpStateStats) if ncu runs here
#   S4 model of N independent rANS streams per 16 KiB (N = 4 / 8 / 32 = entropy units of 4096 / 2048 / 512 bases): size
#      and windows/s per N, same card - the format decision before the freeze
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
g++ -std=c++17 -O3 -march=native -funroll-loops $INC -o $B/refrel3 research/refrel/refrel3.cpp src/aceapex_api.cpp -lzstd -lpthread
g++ -std=c++17 -O3 -march=native -c -o $B/aceapex_api.o src/aceapex_api.cpp
gpu_build() { # <tag> <extra flags> -> $B/refrel3_gpu<tag>; ptxas report in $W/ptxas<tag>.txt
  local tag=$1; shift
  if nvcc -std=c++17 -O3 -arch=native -lineinfo -Xptxas -v --Werror all-warnings "$@" $INC -c -o $B/r3gpu$tag.o research/refrel/refrel3_gpu.cu > $W/ptxas$tag.txt 2>&1; then echo "S0$tag: compiled with --Werror all-warnings"
  else echo "S0$tag: --Werror all-warnings failed - warnings / errors:"; grep -E "warning|error" $W/ptxas$tag.txt | head -40
       nvcc -std=c++17 -O3 -arch=native -lineinfo -Xptxas -v "$@" $INC -c -o $B/r3gpu$tag.o research/refrel/refrel3_gpu.cu > $W/ptxas$tag.txt 2>&1 || { cat $W/ptxas$tag.txt | tail -40; false; }
       echo "S0$tag: compiled without --Werror (warnings above)"; fi
  nvcc -arch=native -o $B/refrel3_gpu$tag $B/r3gpu$tag.o $B/aceapex_api.o -lzstd -lpthread
  grep -E "Compiling entry function|Function properties|Used [0-9]+ registers|spill" $W/ptxas$tag.txt | sed 's/^ptxas info *: *//' | grep -E "r3_kernel|raw_kernel|registers|spill" | head -24 > $W/ptxas$tag.short.txt || true; }
gpu_build ""
cat $W/ptxas.short.txt
cd $W

# ---------------------------------------------------------------- encode (VM) + S1
STAGE=S1
FAS=(); PRE=(); for nm in "${NAMES[@]}"; do FAS+=($D/$nm.fa); PRE+=($D/$nm); done
$B/refrel3 build $FA $D $T "${FAS[@]}" | tee $W/build.txt
for nm in "${NAMES[@]}"; do echo "R3SIZE $nm r3 $(stat -c%s $D/$nm.r3) meta3 $(stat -c%s $D/$nm.meta3.zst) total $(( $(stat -c%s $D/$nm.r3) + $(stat -c%s $D/$nm.meta3.zst) ))" | tee -a $W/build.txt; done
ARGS=(); for i in 0 1 2 3; do ARGS+=(${PRE[$i]} ${FAS[$i]}); done
$B/refrel3_gpu s1 $FA "${ARGS[@]}" | tee $W/s1.txt
grep -q "S1RESULT.*ok" $W/s1.txt

# ---------------------------------------------------------------- S2
STAGE=S2
$B/refrel3_gpu s2 $FA ${PRE[0]} ${FAS[0]} | tee $W/s2.txt
! grep -q FAILED $W/s2.txt

# ---------------------------------------------------------------- S3
STAGE=S3
$B/refrel3_gpu s3 $FA ${PRE[0]} ${FAS[0]} | tee $W/s3.txt
NCU=$(command -v ncu || ls /usr/local/cuda/bin/ncu 2>/dev/null || true)
if [ -n "$NCU" ]; then
  for cfg in "256 65536" "4096 65536"; do set -- $cfg
    $NCU --section SpeedOfLight --section Occupancy --section WarpStateStats -k regex:r3_kernel --launch-count 1 $B/refrel3_gpu one $FA ${PRE[0]} $1 $2 128 > $W/ncu_$1.txt 2>&1 || echo "ncu W=$1: exit $? (see the file)" >> $W/ncu_$1.txt
  done
else echo "ncu not found" > $W/ncu_256.txt; fi

# ---------------------------------------------------------------- S4 model: N independent rANS streams per 16 KiB
STAGE=S4; cd $SRC
for bs in 4096 2048 512; do
  g++ -std=c++17 -O3 -march=native -funroll-loops -DRR_BS=${bs}u $INC -o $B/refrel3_$bs research/refrel/refrel3.cpp src/aceapex_api.cpp -lzstd -lpthread
  gpu_build _$bs -DRR_BS=${bs}u
done
cd $W
$B/refrel3_gpu curves $FA ${PRE[0]} ${FAS[0]} | tee $W/s4_16384.txt
for bs in 4096 2048 512; do mkdir -p $D/bs$bs
  $B/refrel3_$bs build $FA $D/bs$bs $T ${FAS[0]} > $W/s4_build_$bs.txt
  n0=${NAMES[0]}; $B/refrel3_$bs full $FA $D/bs$bs/$n0 $W/rt.fa > /dev/null; cmp $W/rt.fa ${FAS[0]}; rm -f $W/rt.fa
  echo "S4SIZE $bs $(( $(stat -c%s $D/bs$bs/$n0.r3) + $(stat -c%s $D/bs$bs/$n0.meta3.zst) )) (full decode == FASTA)" | tee -a $W/s4_build_$bs.txt
  $B/refrel3_gpu_$bs curves $FA $D/bs$bs/$n0 ${FAS[0]} | tee $W/s4_$bs.txt
done

# ---------------------------------------------------------------- tables
STAGE=report
{ echo "# refrel3 on the GPU - $(cat $W/gpu.txt | head -n 1); aceapex $COMMIT; $(date -u +%FT%TZ); $T host threads"
  echo; echo "## S0 build"; grep -h "^S0" $RUNLOG | sort -u; echo "ptxas (16 KiB blocks):"; cat $W/ptxas.short.txt
  for bs in 4096 2048 512; do echo "ptxas RR_BS=$bs:"; cat $W/ptxas_$bs.short.txt; done
  echo; echo "## encode (VM) and S1 correctness"; cat $W/build.txt | grep -E "^RR3BUILD|^R3SIZE" | cut -c1-260; grep -E "^S1" $W/s1.txt
  echo; echo "## S2 ceiling: raw bases resident vs refrel3, same windows"; grep -E "^S2" $W/s2.txt
  echo; echo "## S3 throttling"; grep -E "^S3|^\[s3\]" $W/s3.txt
  echo; echo "## S3 ncu (r3_kernel, one batch, 128 threads)"; for f in $W/ncu_*.txt; do echo "--- $(basename $f)"; grep -E "Duration|Throughput|Occupancy|Achieved|Registers|Stall|stall|Warp Cycles|Issue|ERR|Error|not found|exit" $f | head -40; done
  echo; echo "## S4 model: entropy unit = 16 KiB / N (independent rANS streams), HG00438.1"
  echo "N 1 (16384): size $(awk '/^R3SIZE HG00438.1/{print $7}' $W/build.txt)"; grep -h "^CURVE" $W/s4_16384.txt
  for bs in 4096 2048 512; do echo "N $((16384 / bs)) ($bs):"; grep -h "^S4SIZE" $W/s4_build_$bs.txt; grep -h "^CURVE" $W/s4_$bs.txt; done
} > $OUT
echo "written: $OUT"
echo "DONE — выключи runtime"
