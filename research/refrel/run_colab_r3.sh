#!/usr/bin/env bash
# run_colab_r3.sh - refrel3 GPU part on Colab (RTX PRO 6000 Blackwell): clones ACEAPEX (branch refrel), builds the CLI, the
# GPU library (open profile, no nvCOMP), the refrel3 CPU tool and refrel3_gpu; T2T FASTA and HPRC assemblies from the Drive
# store gpu_run.sh uses (MyDrive/aceapex_corpus: t2t.fa[.gz], hprc/<name>.fa.gz; missing ones fetched: T2T from NCBI
# with md5, HPRC from the year-1 index with sha256); encodes refrel3 + open on the VM; then on the card:
#   curves   GB/s and windows/s for W = 256 B .. 1 MiB, refrel3 and open, same assembly, same card (64 windows per W checked)
#   capacity reference + HPRC_N assemblies resident, free memory, assemblies that fit on 80 / 96 GiB
# Result: MyDrive/aceapex_logs/refrel3_<date>.txt; on failure the line, the command and the log tail in ..._FAILED.txt.
# Env: REF (default refrel), HPRC_N (4), DRIVE, W
set -Eeuo pipefail
shopt -s nullglob
REF=${REF:-refrel}
DRIVE=${DRIVE:-/content/drive/MyDrive}
STORE=$DRIVE/aceapex_corpus; LOGS=$DRIVE/aceapex_logs
W=${W:-/content/refrel3}; SRC=$W/aceapex; D=$W/rr
HPRC_N=${HPRC_N:-4}
[ -d $DRIVE ] || { echo "Drive not mounted: from google.colab import drive; drive.mount('/content/drive')"; exit 1; }
mkdir -p $W $D $STORE/hprc $LOGS
DAY=$(date -u +%Y-%m-%d); RUNLOG=$W/run-$DAY.log; OUT=$LOGS/refrel3_$DAY.txt
exec > >(tee -a $RUNLOG) 2>&1
on_err() { local rc=$? ln=$1 cmd=$2
  echo "FAILED: exit $rc at line $ln: $cmd"
  { echo "# refrel3 FAILED $(date -u +%FT%TZ): exit $rc at line $ln: $cmd"; tail -n 80 $RUNLOG; } > $LOGS/refrel3_${DAY}_FAILED.txt 2>/dev/null || true
  echo "tail of the log: $LOGS/refrel3_${DAY}_FAILED.txt"; }
trap 'on_err $LINENO "$BASH_COMMAND"' ERR
T=$(nproc)
nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader
SM=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n 1 | tr -d '.')

# code
if [ -d $SRC/.git ]; then git -C $SRC fetch -q origin $REF; git -C $SRC checkout -q FETCH_HEAD; else git clone -q https://github.com/yasha1971-coder/aceapex.git $SRC; git -C $SRC checkout -q $REF; fi
COMMIT=$(git -C $SRC rev-parse HEAD); echo "aceapex $COMMIT ($REF)"
command -v nvcc >/dev/null || export PATH=/usr/local/cuda/bin:$PATH
cd $SRC
make -s aceapex >/dev/null
make -s gpu-lib GPU_ARCH="-arch=sm_$SM"
g++ -std=c++17 -O3 -march=native -funroll-loops -Isrc -Iresearch/refrel -o $W/refrel3 research/refrel/refrel3.cpp src/aceapex_api.cpp -lzstd -lpthread
nvcc -std=c++17 -O3 -arch=sm_$SM -Isrc -Iresearch/refrel -o $W/refrel3_gpu research/refrel/refrel3_gpu.cu src/aceapex_api.cpp -L$SRC -laceapex_gpu -Xlinker -rpath=$SRC -lzstd -lpthread
cd $W

# data
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
awk -F'\t' -v n=$HPRC_N 'NR>1{ if (c++ < n) print $1".1\t"$2"\t"$6; if (c++ < n) print $1".2\t"$3"\t"$7 }' $IDX > $HD/list.tsv
NAMES=()
while IFS=$'\t' read -r nm url sha; do
  u=${url/s3:\/\/human-pangenomics/https:\/\/s3-us-west-2.amazonaws.com\/human-pangenomics}
  if [ ! -s $HD/$nm.fa.gz ]; then curl -fsSL --retry 3 -o $HD/$nm.fa.gz.part "$u"; mv $HD/$nm.fa.gz.part $HD/$nm.fa.gz; fi
  if [ "$(sha256sum $HD/$nm.fa.gz | cut -d' ' -f1)" != "$sha" ]; then echo "HPRC $nm: sha256 mismatch - skipped"; continue; fi
  [ -s $D/$nm.fa ] || gunzip -c $HD/$nm.fa.gz > $D/$nm.fa
  NAMES+=($nm)
done < $HD/list.tsv
[ ${#NAMES[@]} -gt 0 ] || { echo "no HPRC assembly passed sha256"; false; }
echo "HPRC: ${NAMES[*]}"

# encode on the VM: refrel3 (one reference index) and the open archive with the CLI
FAS=(); for nm in "${NAMES[@]}"; do FAS+=($D/$nm.fa); done
$W/refrel3 build $FA $D $T "${FAS[@]}" | tee $W/build.txt
E="env -i PATH=$PATH ACEAPEX_BS=16384 LIT_CHUNK=65536 AX_PROFILE=open $SRC/aceapex c"
for nm in "${NAMES[@]}"; do [ -s $D/$nm.open.aet ] || $E --in $D/$nm.fa --out $D/$nm.open.aet --threads $T >/dev/null
  echo "R3SIZE $nm r3 $(stat -c%s $D/$nm.r3) meta3 $(stat -c%s $D/$nm.meta3.zst) open $(stat -c%s $D/$nm.open.aet)" | tee -a $W/build.txt; done
N0=${NAMES[0]}
$W/refrel3 full $FA $D/$N0 $W/rt.fa; cmp $W/rt.fa $D/$N0.fa; rm -f $W/rt.fa; echo "refrel3 full decode $N0 == FASTA" | tee -a $W/build.txt

# card
$W/refrel3_gpu curves $FA $D/$N0 $D/$N0.fa $D/$N0.open.aet | tee $W/curves.txt
CAPS=(); for nm in "${NAMES[@]}"; do CAPS+=($D/$nm); done
$W/refrel3_gpu capacity $FA "${CAPS[@]}" | tee $W/capacity.txt

{ echo "# refrel3 on $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -n 1), aceapex $COMMIT, $(date -u +%FT%TZ), $T host threads"
  echo "## encode (VM)"; cat $W/build.txt
  echo "## curves: R3GWIN kind W n windows/s GB/s check"; cat $W/curves.txt
  echo "## capacity"; cat $W/capacity.txt
} > $OUT
echo "done: $OUT"
