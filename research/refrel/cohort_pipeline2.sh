#!/usr/bin/env bash
# cohort_pipeline2.sh - cohort_pipeline.sh after 03.10 ~19:40 UTC (user's decision): AGC only with T2T (the archive
# without a reference is no longer extended; its rows up to here stay in agc.tsv), AGC appended in batches of 10 from
# the .fa.gz, at most 10 downloaded sources on disk. Per assembly as before: download (the next one in the background)
# -> hash check -> gunzip -> refrel3 both (v1+carry and refrel3, each decoded back in full == FASTA) -> FASTA deleted ->
# manifest line; the .fa.gz stays until its batch is in AGC, then it is deleted. Same work dir, manifest and job list.
# Usage: research/refrel/cohort_pipeline2.sh <work_dir> <t2t.fa> <refrel3 binary> <aceapex CLI> <agc> <local_gz_dir>
set -uo pipefail
WD=$1; REF=$2; RR3=$3; CLI=$4; AGC=$5; LOCAL=${6:-}
T=$(nproc); MAN=$WD/manifest.tsv; AGCLOG=$WD/agc.tsv; LOG=$WD/pipeline.log; JOBS=$WD/jobs.tsv; BATCH=10
s3(){ echo "${1/s3:\/\/human-pangenomics/https://s3-us-west-2.amazonaws.com/human-pangenomics}"; }
fetch(){ local nm=$1 url=$2 base=${1#y1_}; if [ -n "$LOCAL" ] && [ -s $LOCAL/$base.fa.gz ]; then echo $LOCAL/$base.fa.gz; return 0; fi
  local f=$WD/dl/$nm.fa.gz; [ -s $f ] || { curl -fsSL --retry 5 -o $f.part "$(s3 $url)" && mv $f.part $f; }; echo $f; }
N=$(awk -F'\t' 'NR>1{n=$1} END{print n+0}' $AGCLOG)
echo "$(date -u +%FT%TZ) pipeline2: AGC with T2T only, batches of $BATCH; AGC at N=$N" >> $LOG
PEND=(); PENDN=()
agc_flush(){ [ ${#PEND[@]} -gt 0 ] || return 0
  local a0=$(date +%s.%N)
  if $AGC append -t $T -o $WD/agc/t2t.new $WD/agc/t2t.agc "${PEND[@]}" 2>>$LOG; then mv $WD/agc/t2t.new $WD/agc/t2t.agc; N=$((N + ${#PEND[@]}))
    printf '%d\t%s\t%s\t-\t%.1f\t-\tbatch of %d\n' $N "${PENDN[-1]}" $(stat -c%s $WD/agc/t2t.agc) $(echo "$(date +%s.%N) - $a0" | bc) ${#PEND[@]} >> $AGCLOG
  else echo "$(date -u +%FT%TZ) AGC batch append FAILED (${PENDN[*]})" >> $LOG; fi
  for g in "${PEND[@]}"; do case $g in $WD/dl/*) rm -f $g;; esac; done; PEND=(); PENDN=(); }
mapfile -t L < <(awk -F'\t' 'NR==FNR{done[$1]=1; next} !($1 in done)' $MAN $JOBS)
PREPID=""
for ((i = 0; i < ${#L[@]}; i++)); do
  IFS=$'\t' read -r nm src url ht hv <<< "${L[$i]}"
  t0=$(date +%s)
  if [ -n "$PREPID" ]; then wait $PREPID; fi
  gz=$(fetch "$nm" "$url")
  if (( i + 1 < ${#L[@]} )); then IFS=$'\t' read -r nn ns nu nh nv <<< "${L[$((i+1))]}"; ( fetch "$nn" "$nu" >/dev/null ) & PREPID=$!; else PREPID=""; fi
  st=ok
  if [ "$ht" = md5 ]; then want=$(curl -fsSL --retry 3 "$(s3 $hv)" | awk '{print $1}'); got=$(md5sum $gz | cut -d' ' -f1); else want=$hv; got=$(sha256sum $gz | cut -d' ' -f1); fi
  [ -n "$want" ] && [ "$got" = "$want" ] || st="hash-mismatch"
  r3=-; v1=-; h1=-; h2=-; h3=-; h4=-; h5=-; fb=-
  if [ $st = ok ]; then
    fa=$WD/dl/$nm.fa; gunzip -c $gz > $fa || st="gunzip-failed"; fb=$(stat -c%s $fa 2>/dev/null || echo -)
    if [ $st = ok ]; then line=$($RR3 both $REF $WD/out $T $CLI $fa 2>>$LOG | grep RRBOTH); rc=$?
      [ $rc = 0 ] && echo "$line" | grep -q "both == FASTA" || st="refrel-failed"
      echo "$line" >> $LOG
      v1=$(echo "$line" | awk -F'\t' '{print $4}' | awk '{print $2}'); r3=$(echo "$line" | awk -F'\t' '{print $5}' | awk '{print $2}')
      o=$WD/out/$nm; h1=$(sha256sum $o.r3 | cut -c1-64); h2=$(sha256sum $o.meta3.zst | cut -c1-64); h3=$(sha256sum $o.t0.aet | cut -c1-64); h4=$(sha256sum $o.lit.aet | cut -c1-64); h5=$(sha256sum $o.meta2.zst | cut -c1-64); fi
    rm -f $fa
  fi
  if [ $st = ok ]; then PEND+=("$gz"); PENDN+=("$nm"); else case $gz in $WD/dl/*) rm -f $gz;; esac; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n' "$nm" "$src" "$url" "$ht" "$got" "$st" "$fb" "$v1" "$r3" "$h1" "$h2" "$h3" "$h4" "$h5" $(( $(date +%s) - t0 )) >> $MAN
  echo "$(date -u +%FT%TZ) $nm $st v1carry=$v1 refrel3=$r3 $(( $(date +%s) - t0 )) s" >> $LOG
  [ ${#PEND[@]} -ge $BATCH ] && agc_flush
  [ -e $WD/STOP ] && { agc_flush; echo "STOP file: halted after $nm" >> $LOG; break; }
done
agc_flush
echo "$(date -u +%FT%TZ) PIPELINE DONE" >> $LOG
