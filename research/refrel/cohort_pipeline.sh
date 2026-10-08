#!/usr/bin/env bash
# cohort_pipeline.sh - every available HPRC haplotype assembly through refrel on ace-core, streaming:
#   download (the next one in the background) -> hash check (year-1: sha256 of the index; release 2: the .md5 file next
#   to the assembly) -> AGC append from the .fa.gz into two archives (T2T first; no reference) -> gunzip -> refrel3 both
#   (v1+carry and refrel3, each decoded back in full and compared with the FASTA) -> FASTA and downloaded .fa.gz deleted
#   -> one manifest line (URL, source hash, archive hashes, sizes, times). At most two downloaded assemblies on disk.
# Usage: research/refrel/cohort_pipeline.sh <work_dir> <t2t.fa> <refrel3 binary> <aceapex CLI> <agc> <t2t.agc> <year1 index.tsv> <r2 index.csv> [local_gz_dir]
# Resumable: assemblies with a manifest line are skipped.
set -uo pipefail
WD=$1; REF=$2; RR3=$3; CLI=$4; AGC=$5; T2TAGC=$6; Y1=$7; R2=$8; LOCAL=${9:-}
T=$(nproc); mkdir -p $WD/dl $WD/out $WD/agc
MAN=$WD/manifest.tsv; AGCLOG=$WD/agc.tsv; LOG=$WD/pipeline.log
[ -s $MAN ] || printf 'name\tsource\turl\thash_type\tsource_hash\tstatus\tfasta_bytes\tv1carry_bytes\trefrel3_bytes\tsha256_r3\tsha256_meta3\tsha256_t0\tsha256_lit\tsha256_meta2\tseconds\n' > $MAN
[ -s $AGCLOG ] || printf 'n\tname\tagc_t2t_bytes\tagc_noref_bytes\tappend_t2t_s\tappend_noref_s\n' > $AGCLOG
s3(){ echo "${1/s3:\/\/human-pangenomics/https://s3-us-west-2.amazonaws.com/human-pangenomics}"; }

# job list: year-1 (both haplotypes of every sample, sha256), then release 2 (haplotypes 1/2, not the two references)
JOBS=$WD/jobs.tsv
if [ ! -s $JOBS ]; then
  awk -F'\t' 'NR>1{print "y1_"$1".1\ty1\t"$2"\tsha256\t"$6; print "y1_"$1".2\ty1\t"$3"\tsha256\t"$7}' $Y1 > $JOBS
  python3 - "$R2" >> $JOBS <<'PY'
import csv, sys
for x in csv.DictReader(open(sys.argv[1])):
    if x['haplotype'] in ('1', '2'): print(f"r2_{x['assembly_name']}\tr2\t{x['assembly']}\tmd5\t{x['assembly_md5']}")
PY
fi
echo "$(date -u +%FT%TZ) start: $(wc -l < $JOBS) jobs, $(($(wc -l < $MAN) - 1)) done" >> $LOG

fetch(){ # name url -> $WD/dl/name.fa.gz (or the local copy); prints the path
  local nm=$1 url=$2 base=${1#y1_}; if [ -n "$LOCAL" ] && [ -s $LOCAL/$base.fa.gz ]; then echo $LOCAL/$base.fa.gz; return 0; fi
  local f=$WD/dl/$nm.fa.gz; [ -s $f ] || curl -fsSL --retry 5 -o $f.part "$(s3 $url)" && mv $f.part $f 2>/dev/null; echo $f; }

mapfile -t L < <(awk -F'\t' 'NR==FNR{done[$1]=1; next} !($1 in done)' $MAN $JOBS)
N=$(($(wc -l < $AGCLOG) - 1))
[ -s $WD/agc/t2t.agc ] || cp $T2TAGC $WD/agc/t2t.agc
PRE=""; PREPID=""
for ((i = 0; i < ${#L[@]}; i++)); do
  IFS=$'\t' read -r nm src url ht hv <<< "${L[$i]}"
  t0=$(date +%s)
  if [ -n "$PREPID" ]; then wait $PREPID; fi
  gz=$(fetch "$nm" "$url")                                       # already there if prefetched
  if (( i + 1 < ${#L[@]} )); then IFS=$'\t' read -r nn ns nu nh nv <<< "${L[$((i+1))]}"; ( fetch "$nn" "$nu" >/dev/null ) & PREPID=$!; else PREPID=""; fi
  st=ok
  if [ "$ht" = md5 ]; then want=$(curl -fsSL --retry 3 "$(s3 $hv)" | awk '{print $1}'); got=$(md5sum $gz | cut -d' ' -f1); else want=$hv; got=$(sha256sum $gz | cut -d' ' -f1); fi
  [ -n "$want" ] && [ "$got" = "$want" ] || st="hash-mismatch"
  r3=-; v1=-; h1=-; h2=-; h3=-; h4=-; h5=-; fb=-
  if [ $st = ok ]; then
    # AGC: two archives grow by one assembly (from the .fa.gz)
    a0=$(date +%s.%N); $AGC append -t 8 -o $WD/agc/t2t.new $WD/agc/t2t.agc $gz 2>>$LOG & P1=$!
    if [ -s $WD/agc/noref.agc ]; then $AGC append -t 8 -o $WD/agc/noref.new $WD/agc/noref.agc $gz 2>>$LOG & P2=$!; else $AGC create -t 8 -o $WD/agc/noref.new $gz 2>>$LOG & P2=$!; fi
    wait $P1; r1=$?; a1=$(date +%s.%N); wait $P2; r2=$?; a2=$(date +%s.%N)
    if [ $r1 = 0 ] && [ $r2 = 0 ]; then mv $WD/agc/t2t.new $WD/agc/t2t.agc; mv $WD/agc/noref.new $WD/agc/noref.agc; N=$((N + 1))
      printf '%d\t%s\t%s\t%s\t%.1f\t%.1f\n' $N $nm $(stat -c%s $WD/agc/t2t.agc) $(stat -c%s $WD/agc/noref.agc) $(echo "$a1 - $a0" | bc) $(echo "$a2 - $a0" | bc) >> $AGCLOG
    else st="agc-failed"; fi
    fa=$WD/dl/$nm.fa; gunzip -c $gz > $fa || st="gunzip-failed"; fb=$(stat -c%s $fa 2>/dev/null || echo -)
    if [ $st = ok ]; then line=$($RR3 both $REF $WD/out $T $CLI $fa 2>>$LOG | grep RRBOTH); rc=$?
      [ $rc = 0 ] && echo "$line" | grep -q "both == FASTA" || st="refrel-failed"
      echo "$line" >> $LOG
      v1=$(echo "$line" | awk -F'\t' '{print $4}' | awk '{print $2}'); r3=$(echo "$line" | awk -F'\t' '{print $5}' | awk '{print $2}')
      o=$WD/out/$nm; h1=$(sha256sum $o.r3 | cut -c1-64); h2=$(sha256sum $o.meta3.zst | cut -c1-64); h3=$(sha256sum $o.t0.aet | cut -c1-64); h4=$(sha256sum $o.lit.aet | cut -c1-64); h5=$(sha256sum $o.meta2.zst | cut -c1-64); fi
    rm -f $fa
  fi
  case $gz in $WD/dl/*) rm -f $gz;; esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n' "$nm" "$src" "$url" "$ht" "$got" "$st" "$fb" "$v1" "$r3" "$h1" "$h2" "$h3" "$h4" "$h5" $(( $(date +%s) - t0 )) >> $MAN
  echo "$(date -u +%FT%TZ) $nm $st v1carry=$v1 refrel3=$r3 $(( $(date +%s) - t0 )) s" >> $LOG
  [ -e $WD/STOP ] && { echo "STOP file: halted after $nm" >> $LOG; break; }
done
echo "$(date -u +%FT%TZ) PIPELINE DONE" >> $LOG
