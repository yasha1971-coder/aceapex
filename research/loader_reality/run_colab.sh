#!/usr/bin/env bash
# run_colab.sh - loader_reality on Colab (RTX PRO 6000 Blackwell, sm_120): clones ACEAPEX, builds the GPU library
# (open profile: no nvCOMP), installs torch / pyfaidx if missing, takes T2T (.open.aet + FASTA) and the HPRC .open.aet
# from the Drive store gpu_run.sh uses (MyDrive/aceapex_corpus: cache/t2t.open.aet, t2t.fa[.gz], hprc/*.open.aet);
# what is missing is fetched as gpu_run.sh fetches it (T2T from NCBI, md5 checked; HPRC from the year-1 index, sha256
# checked) and encoded with the CLI. Result tables: MyDrive/aceapex_logs/loader_reality_<date>.txt.
# Run in a Colab cell after mounting Drive (from google.colab import drive; drive.mount("/content/drive")).
# Env: REF (git ref, default loader-reality), STORE, HPRC_N (HPRC archives for the capacity table, default 2), STEPS (10)
set -euo pipefail
REF=${REF:-loader-reality}
STORE=${STORE:-/content/drive/MyDrive/aceapex_corpus}
LOGS=/content/drive/MyDrive/aceapex_logs
W=/content/loader_reality; SRC=$W/aceapex
HPRC_N=${HPRC_N:-2}; STEPS=${STEPS:-10}
[ -d /content/drive/MyDrive ] || { echo "Drive not mounted: from google.colab import drive; drive.mount('/content/drive')"; exit 1; }
mkdir -p $W $STORE/cache $STORE/hprc $LOGS
nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader
SM=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n 1 | tr -d '.')

# code
if [ -d $SRC/.git ]; then git -C $SRC fetch -q origin $REF && git -C $SRC checkout -q FETCH_HEAD; else git clone -q https://github.com/yasha1971-coder/aceapex.git $SRC && git -C $SRC checkout -q $REF; fi
echo "aceapex $(git -C $SRC rev-parse HEAD) ($REF)"
command -v nvcc >/dev/null || export PATH=/usr/local/cuda/bin:$PATH
( cd $SRC && make -s aceapex >/dev/null && make -s gpu-lib GPU_ARCH="-arch=sm_$SM" )
LIB=$SRC/libaceapex_gpu.so.1; [ -s $LIB ] || { echo "GPU library not built"; exit 1; }
python3 -c "import torch" 2>/dev/null || pip -q install torch
python3 -c "import pyfaidx" 2>/dev/null || pip -q install pyfaidx

# T2T FASTA and archive
FA=$W/t2t.fa
if [ ! -s $FA ]; then
  if [ -s $STORE/t2t.fa ]; then cp $STORE/t2t.fa $FA
  elif [ -s $STORE/t2t.fa.gz ]; then gunzip -c $STORE/t2t.fa.gz > $FA
  else curl -fsSL --retry 3 -o $W/t2t.fa.gz https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/009/914/755/GCA_009914755.4_T2T-CHM13v2.0/GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz
    gunzip -c $W/t2t.fa.gz > $FA; cp $W/t2t.fa.gz $STORE/t2t.fa.gz; rm -f $W/t2t.fa.gz; fi
fi
echo "cd1e52ce400c027ed0b7ab4b9d613f5a  $FA" | md5sum -c -
A=$W/t2t.open.aet
if [ ! -s $A ]; then
  if [ -s $STORE/cache/t2t.open.aet ]; then cp $STORE/cache/t2t.open.aet $A
  else env -i PATH=$PATH ACEAPEX_BS=16384 LIT_CHUNK=65536 AX_PROFILE=open $SRC/aceapex c --in $FA --out $A --threads $(nproc) >/dev/null; cp $A $STORE/cache/t2t.open.aet; fi
fi
$SRC/aceapex d --in $A --out $W/t2t.rt >/dev/null && cmp $W/t2t.rt $FA && rm -f $W/t2t.rt && echo "t2t.open.aet: $(stat -c%s $A) B, round trip == FASTA"

# HPRC archives for the capacity table: the ones in the store, else the first HPRC_N of the year-1 index
HD=$STORE/hprc; NA=$(ls $HD/*.open.aet 2>/dev/null | wc -l)
if [ $NA -lt $HPRC_N ]; then
  IDX=$HD/index.tsv
  [ -s $IDX ] || curl -fsSL -o $IDX https://raw.githubusercontent.com/human-pangenomics/HPP_Year1_Assemblies/main/assembly_index/Year1_assemblies_v2_genbank.index
  awk -F'\t' 'NR>1{print $1".1\t"$2"\t"$6; print $1".2\t"$3"\t"$7}' $IDX | head -n $HPRC_N > $HD/list.tsv
  while IFS=$'\t' read -r nm url sha; do
    [ -s $HD/$nm.open.aet ] && continue
    u=${url/s3:\/\/human-pangenomics/https:\/\/s3-us-west-2.amazonaws.com\/human-pangenomics}
    [ -s $HD/$nm.fa.gz ] || { curl -fsSL --retry 3 -o $HD/$nm.fa.gz.part "$u" && mv $HD/$nm.fa.gz.part $HD/$nm.fa.gz; }
    [ "$(sha256sum $HD/$nm.fa.gz | cut -d' ' -f1)" = "$sha" ] || { echo "HPRC $nm: sha256 mismatch - skipped"; continue; }
    gunzip -c $HD/$nm.fa.gz > $W/h.fa
    env -i PATH=$PATH ACEAPEX_BS=16384 LIT_CHUNK=65536 AX_PROFILE=open $SRC/aceapex c --in $W/h.fa --out $HD/$nm.open.aet --threads $(nproc) >/dev/null
    rm -f $W/h.fa; echo "HPRC $nm: $(stat -c%s $HD/$nm.open.aet) B"
  done < $HD/list.tsv
fi

OUT=$LOGS/loader_reality_$(date -u +%Y-%m-%d).txt
python3 $SRC/research/loader_reality/loader_reality.py --lib $LIB --archive $A --fasta $FA --hprc-dir $HD --steps $STEPS --out $OUT
{ echo; echo "# aceapex $(git -C $SRC rev-parse HEAD), GPU library -arch=sm_$SM, $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -n 1)"; } >> $OUT
echo "done: $OUT"
