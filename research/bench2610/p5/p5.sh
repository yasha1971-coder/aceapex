#!/usr/bin/env bash
# p5.sh - P5 truth tables (SHA-256 per answer) for P1 and P3 from the uncompressed FASTA with samtools 1.24.
set -euo pipefail
ulimit -c 0
D=$(cd "$(dirname "$0")" && pwd); W=$HOME/pubrepo/.wk/p5; mkdir -p $W/fa $W/truth_p1 $W/truth_p3
export LD_LIBRARY_PATH=$HOME/build/htslib-latest/lib; ST=$HOME/build/htslib-latest/bin/samtools; MAN=$HOME/pubrepo/.wk/hprc_cohort/v1/manifest_v1.tsv
$ST --version | head -2 > $W/versions.txt
ln -sf $HOME/golden/genome/chr1.fa $W/fa/chr1.fa; ln -sf $HOME/golden/genome/t2t.fa $W/fa/t2t.fa
for n in HG00438.1 HG00438.2 HG00621.1 HG00621.2; do
  want=$(awk -F'\t' -v n=y1_$n '$1==n{print $4}' $MAN); have=$(sha256sum $HOME/pubrepo/.wk/hprc50/$n.fa.gz | cut -d' ' -f1)
  [ "$want" = "$have" ]; [ -s $W/fa/$n.fa ] || gunzip -c $HOME/pubrepo/.wk/hprc50/$n.fa.gz > $W/fa/$n.fa; done
for f in $W/fa/*.fa; do [ -s $f.fai ] || $ST faidx $f; done
python3 $D/make_requests.py $W $HOME/pubrepo/.wk/agc558/truth558m.tsv
for r in $W/req_p1/*.tsv; do python3 $D/truth_samtools.py $W $r $W/truth_p1/$(basename $r); done
