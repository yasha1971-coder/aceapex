#!/usr/bin/env bash
# run_colab.sh - refrel GPU part on Colab (RTX PRO 6000 Blackwell): clones ACEAPEX (branch refrel), builds the CLI, the
# GPU library (open profile, no nvCOMP), the refrel CPU tool and refrel_gpu; T2T FASTA and HPRC assemblies from the Drive
# store gpu_run.sh uses (MyDrive/aceapex_corpus: t2t.fa[.gz], hprc/<name>.fa.gz; missing ones fetched: T2T from NCBI
# with md5, HPRC from the year-1 index with sha256); encodes refrel + open on the VM; then on the card:
#   curves   GB/s and windows/s for W = 256 B .. 1 MiB, refrel and open, same assembly, same card (64 windows per W checked)
#   capacity reference + HPRC_N assemblies resident, free memory, assemblies that fit on 80 / 96 GiB
#   ncu      L2 hit rate, DRAM bytes and time of the refrel kernel and of the open windows kernels (W 4 KiB, n 65 536)
# Result: MyDrive/aceapex_logs/refrel_<date>.txt; on failure the line, the command and the log tail in ..._FAILED.txt.
# Env: REF (default refrel), HPRC_N (4), DRIVE, W
set -Eeuo pipefail
shopt -s nullglob
REF=${REF:-refrel}
DRIVE=${DRIVE:-/content/drive/MyDrive}
STORE=$DRIVE/aceapex_corpus; LOGS=$DRIVE/aceapex_logs
W=${W:-/content/refrel}; SRC=$W/aceapex; D=$W/rr
HPRC_N=${HPRC_N:-4}
[ -d $DRIVE ] || { echo "Drive not mounted: from google.colab import drive; drive.mount('/content/drive')"; exit 1; }
mkdir -p $W $D $STORE/hprc $LOGS
DAY=$(date -u +%Y-%m-%d); RUNLOG=$W/run-$DAY.log; OUT=$LOGS/refrel_$DAY.txt
exec > >(tee -a $RUNLOG) 2>&1
on_err() { local rc=$? ln=$1 cmd=$2
  echo "FAILED: exit $rc at line $ln: $cmd"
  { echo "# refrel FAILED $(date -u +%FT%TZ): exit $rc at line $ln: $cmd"; tail -n 80 $RUNLOG; } > $LOGS/refrel_${DAY}_FAILED.txt 2>/dev/null || true
  echo "tail of the log: $LOGS/refrel_${DAY}_FAILED.txt"; }
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
g++ -std=c++17 -O3 -march=native -funroll-loops -Isrc -o $W/refrel research/refrel/refrel.cpp src/aceapex_api.cpp -lzstd -lpthread
nvcc -std=c++17 -O3 -arch=sm_$SM -Isrc -Iresearch/refrel -o $W/refrel_gpu research/refrel/refrel_gpu.cu -L$SRC -laceapex_gpu -Xlinker -rpath=$SRC -lzstd
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

# encode on the VM: refrel (one reference index), the two streams and the open archive with the CLI
FAS=(); for nm in "${NAMES[@]}"; do FAS+=($D/$nm.fa); done
$W/refrel build $FA $D $T "${FAS[@]}" | tee $W/build.txt
E="env -i PATH=$PATH ACEAPEX_BS=16384 LIT_CHUNK=65536 AX_PROFILE=open $SRC/aceapex c"
for nm in "${NAMES[@]}"; do
  $E --in $D/$nm.tok --out $D/$nm.tok.aet --threads $T >/dev/null; $E --in $D/$nm.lit --out $D/$nm.lit.aet --threads $T >/dev/null
  [ -s $D/$nm.open.aet ] || $E --in $D/$nm.fa --out $D/$nm.open.aet --threads $T >/dev/null
  echo "RRSIZE $nm tok $(stat -c%s $D/$nm.tok.aet) lit $(stat -c%s $D/$nm.lit.aet) meta $(stat -c%s $D/$nm.meta.zst) open $(stat -c%s $D/$nm.open.aet)" | tee -a $W/build.txt
done
N0=${NAMES[0]}
$W/refrel full $FA $D/$N0 $W/rt.fa; cmp $W/rt.fa $D/$N0.fa; rm -f $W/rt.fa; echo "refrel full decode $N0 == FASTA" | tee -a $W/build.txt

# card
$W/refrel_gpu curves $FA $D/$N0 $D/$N0.fa $D/$N0.open.aet | tee $W/curves.txt
CAPS=(); for nm in "${NAMES[@]}"; do CAPS+=($D/$nm); done
$W/refrel_gpu capacity $FA "${CAPS[@]}" | tee $W/capacity.txt
NCU=$(command -v ncu || true); [ -n "$NCU" ] || NCU=$(ls /usr/local/cuda/bin/ncu 2>/dev/null || true)
if [ -n "$NCU" ]; then
  $NCU --metrics lts__t_sector_hit_rate.pct,dram__bytes_read.sum,gpu__time_duration.sum,sm__throughput.avg.pct_of_peak_sustained_elapsed \
       -k regex:'rr_kernel|k_decode_list|kw_gather|k_rans_n|k_open' $W/refrel_gpu one $FA $D/$N0 $D/$N0.open.aet 4096 65536 > $W/ncu.txt 2>&1 || echo "ncu failed (exit $?): see the tail below" >> $W/ncu.txt
else echo "ncu not found" > $W/ncu.txt; fi

{ echo "# refrel on $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -n 1), aceapex $COMMIT, $(date -u +%FT%TZ), $T host threads"
  echo "## encode (VM)"; cat $W/build.txt
  echo "## curves: RGWIN kind W n windows/s GB/s host-us-per-batch check"; cat $W/curves.txt
  echo "## capacity"; cat $W/capacity.txt
  echo "## ncu"; grep -E "rr_kernel|k_decode_list|kw_gather|k_rans|k_open|lts__t_sector_hit_rate|dram__bytes_read|gpu__time_duration|sm__throughput|ERR|ncu" $W/ncu.txt | head -120
} > $OUT
echo "done: $OUT"
