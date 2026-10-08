#!/usr/bin/env bash
# p5_p3.sh - P5 truth for PROTOCOL_COHORT_REGION: (a) all 558 from the q16k v1 archives decoded with every check
# (truth_v1: FASTA XXH3 == the source's), (b) the 50 with sources on disk by samtools 1.24 on the uncompressed FASTA
# (one at a time: gunzip -> faidx -> 20 regions -> delete); (a) and (b) must agree on the 50.
set -euo pipefail
ulimit -c 0
D=$(cd "$(dirname "$0")" && pwd); W=$HOME/pubrepo/.wk/p5; R=$W/req_p3/requests.tsv
export LD_LIBRARY_PATH=$HOME/build/htslib-latest/lib; ST=$HOME/build/htslib-latest/bin/samtools; MAN=$HOME/pubrepo/.wk/hprc_cohort/v1/manifest_v1.tsv
$HOME/pubrepo/.wk/avr/truth_v1 $HOME/golden/genome/t2t.fa $HOME/pubrepo/.wk/hprc_cohort/v1 $HOME/pubrepo/.wk/agc558/names_identity.tsv $R > $W/truth_p3_v1_raw.tsv 2> $W/truth_p3_v1.err
{ echo -e "id\tsha256"; awk -F'\t' '$1=="REQ"{print $2"\t"$3}' $W/truth_p3_v1_raw.tsv; } > $W/truth_p3/truth_v1.tsv
mkdir -p $W/tmp50; echo -e "id\tsha256" > $W/truth_p3/truth_samtools50.tsv
awk -F'\t' 'NR>1 && NR<=51{print $1"\t"$4}' $MAN | while IFS=$'\t' read -r name sha; do
  s=${name#y1_}; [ "$(sha256sum $HOME/pubrepo/.wk/hprc50/$s.fa.gz | cut -d' ' -f1)" = "$sha" ]
  gunzip -c $HOME/pubrepo/.wk/hprc50/$s.fa.gz > $W/tmp50/$name.fa; $ST faidx $W/tmp50/$name.fa
  ln -sf $W/tmp50/$name.fa $W/fa/$name.fa; ln -sf $W/tmp50/$name.fa.fai $W/fa/$name.fa.fai
  awk -F'\t' -v n="$name" 'NR==1 || $2==n' $R > $W/tmp50/req.tsv
  python3 $D/truth_samtools.py $W $W/tmp50/req.tsv $W/tmp50/out.tsv > /dev/null
  tail -n +2 $W/tmp50/out.tsv >> $W/truth_p3/truth_samtools50.tsv
  rm -f $W/fa/$name.fa $W/fa/$name.fa.fai $W/tmp50/$name.fa $W/tmp50/$name.fa.fai
done
python3 - $W <<'PY'
import sys; W=sys.argv[1]
a=dict(l.rstrip('\n').split('\t') for l in open(W+'/truth_p3/truth_v1.tsv') if not l.startswith('id\t'))
b=dict(l.rstrip('\n').split('\t') for l in open(W+'/truth_p3/truth_samtools50.tsv') if not l.startswith('id\t'))
same=sum(a[k]==v for k,v in b.items()); print(f"P3 truth: v1 {len(a)} answers; samtools {len(b)} answers (50 assemblies); equal on the 50: {same}/{len(b)}")
PY
