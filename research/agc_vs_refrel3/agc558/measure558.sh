#!/usr/bin/env bash
# measure558.sh - PROTOCOL_AGC558 section 4: refrel3 q4k / q16k and AGC (agc558.agc: one create, integrity PASS) on the
# same 558, same requests (manifest names), silence gate first, 3 warm-ups + 9 timed runs, threads 1 (taskset -c 3) and
# 16; AGC in process (libagc e67e3fc) and AGC CLI (bin/agc e67e3fc) as separate rows. Logs: logs/<label>.log.
set -uo pipefail
ulimit -c 0
D=$(cd "$(dirname "$0")" && pwd); L=$D/logs; mkdir -p $L; B=$HOME/pubrepo/.wk/avr; W=$HOME/pubrepo/.wk/agc558
REF=$HOME/golden/genome/t2t.fa; V1=$HOME/pubrepo/.wk/hprc_cohort/v1; AGC=$W/agc558.agc; AGCBIN=$HOME/pubrepo/.wk/tools/agc-src/bin/agc
TR=$W/truth558m.tsv; WIN=$W/req/windows_8192.tsv; REG=$W/req/regions.tsv; export AVR_NAMES=$W/names_identity.tsv
S4=$(head -4 $AVR_NAMES | cut -f1 | paste -sd,)
until awk '{exit !($1<0.5)}' /proc/loadavg; do sleep 5; done
{ echo "# silence gate $(date -u +%FT%TZ)"; echo "loadavg: $(cat /proc/loadavg)"; echo "df: $(df -h / | tail -1 | awk '{print $4" free of "$2}')"; echo "mem: $(free -g | awk '/Mem:/{print $7" GB available of "$2}')"
  echo "top processes by CPU:"; ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu | head -8
  echo "background (not stopped):"; ps -eo user,pcpu,pmem,comm,args | awk '/openhands|glyph/ && !/awk/{print $1, $2, $3, $4}' | sort | uniq -c; } > $L/silence_gate.txt
run() { local label=$1 T=$2; shift 2; local pin=(); [ "$T" = 1 ] && pin=(taskset -c 3)
  { echo "# $label start $(date -u +%FT%TZ) loadavg $(cat /proc/loadavg)"; "${pin[@]}" "$@"; echo "# exit $? end $(date -u +%FT%TZ) loadavg $(cat /proc/loadavg)"; } > $L/$label.log 2>&1; }
for T in 1 16; do
  for ds in q4k q16k; do
    run rr3_${ds}_windows_t$T $T $B/rr3bench req $REF $V1 $ds $WIN $TR $T 3 9 rr3_${ds}_windows_t$T
    run rr3_${ds}_regions_t$T $T $B/rr3bench req $REF $V1 $ds $REG $TR $T 3 9 rr3_${ds}_regions_t$T
    run rr3_${ds}_sample4_t$T $T $B/rr3bench sample $REF $V1 $ds $S4 $TR $T 3 9 rr3_${ds}_sample4_t$T
  done
  run agc_windows_t$T $T $B/agcbench req $AGC $WIN $TR $T 3 9 agc_windows_t$T
  run agc_regions_t$T $T $B/agcbench req $AGC $REG $TR $T 3 9 agc_regions_t$T
  run agc_sample4_t$T $T $B/agcbench sample $AGC $S4 $TR $T 3 9 agc_sample4_t$T
  run agccli_windows_t$T $T python3 $D/../agc_cli_batch.py $AGCBIN $AGC $WIN $TR $T 3 9 agccli_windows_t$T
  run agccli_regions_t$T $T python3 $D/../agc_cli_batch.py $AGCBIN $AGC $REG $TR $T 3 9 agccli_regions_t$T
done
echo "# all done $(date -u +%FT%TZ)" > $L/DONE
