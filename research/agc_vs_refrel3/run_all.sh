#!/usr/bin/env bash
# run_all.sh - AGC 3.2.4 vs refrel3 v1 on HPRC N=50 (the first 50 rows of the v1 manifest), ace-core. Silence gate
# (load < 0.5, > 20 GB free; background recorded), then every configuration one after another; 3 warm-ups + 9 timed
# runs (ONLY50=1: only the all-50 pass, own gate file; all-50 whole samples: 1 timed run, one sample in memory at a time - mode each); threads 1 (taskset -c 3) and 16. Logs: logs/<label>.log.
set -uo pipefail
ulimit -c 0   # no core dumps from test runs
A=${A:?work dir}; L=$(cd "$(dirname "$0")" && pwd)/logs; mkdir -p $L
REF=$HOME/golden/genome/t2t.fa; V1=$HOME/pubrepo/.wk/hprc_cohort/v1; AGCD=$HOME/pubrepo/.wk/refrel/agc; AGCBIN=$HOME/pubrepo/.wk/tl/agc
TR=$A/truth_all.tsv; WIN=$A/req/windows_8192.tsv; REG=$A/req/regions.tsv
S4=$(awk -F'\t' 'NR>1 && NR<=5{sub(/^y1_/,"",$1); printf "%s%s", (NR>2?",":""), $1}' $V1/manifest_v1.tsv)
S50=$(awk -F'\t' 'NR>1 && NR<=51{sub(/^y1_/,"",$1); printf "%s%s", (NR>2?",":""), $1}' $V1/manifest_v1.tsv)
until awk '{exit !($1<0.5)}' /proc/loadavg; do sleep 5; done
{ echo "# silence gate $(date -u +%FT%TZ)"; echo "loadavg: $(cat /proc/loadavg)"; echo "df: $(df -h / | tail -1 | awk '{print $4" free of "$2}')"
  echo "top processes by CPU:"; ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu | head -8
  echo "background (not stopped):"; ps -eo user,pcpu,pmem,comm,args | awk '/openhands|glyph/ && !/awk/{print $1, $2, $3, $4}' | sort | uniq -c; } > $L/silence_gate${ONLY50:+_all50}.txt
run() { local label=$1 T=$2; shift 2; local pin=(); [ "$T" = 1 ] && pin=(taskset -c 3)
  { echo "# $label start $(date -u +%FT%TZ) loadavg $(cat /proc/loadavg)"; "${pin[@]}" "$@"; echo "# exit $? end $(date -u +%FT%TZ) loadavg $(cat /proc/loadavg)"; } > $L/$label.log 2>&1; }
[ -n "${ONLY50:-}" ] || for T in 1 16; do
  for ds in q4k q16k; do
    run rr3_${ds}_windows_t$T $T $A/rr3bench req $REF $V1 $ds $WIN $TR $T 3 9 rr3_${ds}_windows_t$T
    run rr3_${ds}_regions_t$T $T $A/rr3bench req $REF $V1 $ds $REG $TR $T 3 9 rr3_${ds}_regions_t$T
    run rr3_${ds}_sample4_t$T $T $A/rr3bench sample $REF $V1 $ds $S4 $TR $T 3 9 rr3_${ds}_sample4_t$T
  done
  for ar in t2t_50 noref_50; do
    run agc_${ar}_windows_t$T $T $A/agcbench req $AGCD/$ar.agc $WIN $TR $T 3 9 agc_${ar}_windows_t$T
    run agc_${ar}_regions_t$T $T $A/agcbench req $AGCD/$ar.agc $REG $TR $T 3 9 agc_${ar}_regions_t$T
    run agc_${ar}_sample4_t$T $T $A/agcbench sample $AGCD/$ar.agc $S4 $TR $T 3 9 agc_${ar}_sample4_t$T
    run agccli_${ar}_windows_t$T $T python3 $(dirname "$0")/agc_cli_batch.py $AGCBIN $AGCD/$ar.agc $WIN $TR $T 3 9 agccli_${ar}_windows_t$T
    run agccli_${ar}_regions_t$T $T python3 $(dirname "$0")/agc_cli_batch.py $AGCBIN $AGCD/$ar.agc $REG $TR $T 3 9 agccli_${ar}_regions_t$T
  done
done
for T in 16 1; do
  for ds in q4k q16k; do run rr3_${ds}_sample50_t$T $T $A/rr3bench each $REF $V1 $ds $S50 $TR $T 0 1 rr3_${ds}_sample50_t$T; done
  for ar in t2t_50 noref_50; do run agc_${ar}_sample50_t$T $T $A/agcbench each $AGCD/$ar.agc $S50 $TR $T 0 1 agc_${ar}_sample50_t$T; done
done
echo "# all done $(date -u +%FT%TZ)" > $L/DONE
