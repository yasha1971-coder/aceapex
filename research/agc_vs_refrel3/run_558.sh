#!/usr/bin/env bash
# run_558.sh - AGC 3.2.4 (t2t.agc: T2T + the 558 HPRC sets + CHM13 v1.1 + GRCh38 = 561 sets, built by a chain of
# appends - create T2T, then append one by one up to N = 88 and in batches of 10 after; NOT one create) vs refrel3 v1
# (q4k, q16k) on all 558, ace-core, same tools as N = 50 (run_all.sh). Truth: truth_v1 (every v1 archive decoded with
# every check, FASTA XXH3 == source) - the sources of 508 sets are not on disk. Silence gate first; 3 warm-ups + 9 timed
# runs; threads 1 (taskset -c 3) and 16; whole samples: the first 4 of the manifest. Logs: logs558/<label>.log.
set -uo pipefail
ulimit -c 0
A=${A:?work dir}; L=$(cd "$(dirname "$0")" && pwd)/logs558; mkdir -p $L
REF=$HOME/golden/genome/t2t.fa; V1=$HOME/pubrepo/.wk/hprc_cohort/v1; AGC=$HOME/pubrepo/.wk/hprc_cohort/agc/t2t.agc; AGCBIN=$HOME/pubrepo/.wk/tl/agc
TR=$A/truth558.tsv; WIN=$A/req558/windows_8192.tsv; REG=$A/req558/regions.tsv; export AVR_NAMES=$A/agc558_names.tsv
S4=$(head -4 $AVR_NAMES | cut -f2 | paste -sd,)
until awk '{exit !($1<0.5)}' /proc/loadavg; do sleep 5; done
{ echo "# silence gate $(date -u +%FT%TZ)"; echo "loadavg: $(cat /proc/loadavg)"; echo "df: $(df -h / | tail -1 | awk '{print $4" free of "$2}')"; echo "mem: $(free -g | awk '/Mem:/{print $7" GB available of "$2}')"
  echo "top processes by CPU:"; ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu | head -8
  echo "background (not stopped):"; ps -eo user,pcpu,pmem,comm,args | awk '/openhands|glyph/ && !/awk/{print $1, $2, $3, $4}' | sort | uniq -c; } > $L/silence_gate.txt
run() { local label=$1 T=$2; shift 2; local pin=(); [ "$T" = 1 ] && pin=(taskset -c 3)
  { echo "# $label start $(date -u +%FT%TZ) loadavg $(cat /proc/loadavg)"; "${pin[@]}" "$@"; echo "# exit $? end $(date -u +%FT%TZ) loadavg $(cat /proc/loadavg)"; } > $L/$label.log 2>&1; }
for T in 1 16; do
  for ds in q4k q16k; do
    run rr3_${ds}_windows_t$T $T $A/rr3bench req $REF $V1 $ds $WIN $TR $T 3 9 rr3_${ds}_windows_t$T
    run rr3_${ds}_regions_t$T $T $A/rr3bench req $REF $V1 $ds $REG $TR $T 3 9 rr3_${ds}_regions_t$T
    run rr3_${ds}_sample4_t$T $T $A/rr3bench sample $REF $V1 $ds $S4 $TR $T 3 9 rr3_${ds}_sample4_t$T
  done
  run agc_t2t_windows_t$T $T $A/agcbench req $AGC $WIN $TR $T 3 9 agc_t2t_windows_t$T
  run agc_t2t_regions_t$T $T $A/agcbench req $AGC $REG $TR $T 3 9 agc_t2t_regions_t$T
  run agc_t2t_sample4_t$T $T $A/agcbench sample $AGC $S4 $TR $T 3 9 agc_t2t_sample4_t$T
  run agccli_t2t_windows_t$T $T python3 $(dirname "$0")/agc_cli_batch.py $AGCBIN $AGC $WIN $TR $T 3 9 agccli_t2t_windows_t$T
  run agccli_t2t_regions_t$T $T python3 $(dirname "$0")/agc_cli_batch.py $AGCBIN $AGC $REG $TR $T 3 9 agccli_t2t_regions_t$T
done
echo "# all done $(date -u +%FT%TZ)" > $L/DONE
