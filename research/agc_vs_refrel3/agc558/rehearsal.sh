#!/usr/bin/env bash
# rehearsal.sh - PROTOCOL_AGC558 section 3a: agc create through FIFOs on the 50 sets of t2t_50.agc (names and listset
# order of t2t_50.agc; fed from the q16k v1 archives y1_<name>), parameters of section 2; SHA-256 against t2t_50.agc;
# wall time and peak RSS (/usr/bin/time -v).
set -euo pipefail
ulimit -c 0
W=$HOME/pubrepo/.wk/agcm/rh; mkdir -p $W/in; cd $W
G=$HOME/pubrepo/.wk/tools/agc-src/bin/agc; REF=$HOME/golden/genome/t2t.fa; OLD=$HOME/pubrepo/.wk/refrel/agc/t2t_50.agc
"$G" listset "$OLD" | grep -v -x t2t > names50.txt
[ "$(wc -l < names50.txt)" = 50 ]
"$HOME/pubrepo/.wk/avr/fifo_feed" "$REF" "$HOME/pubrepo/.wk/hprc_cohort/v1" q16k "$W/in" 4 $(sed 's|.*|&=y1_&|' names50.txt) 2> feed50.log & FP=$!
until [ "$(find in -type p | wc -l)" = 50 ]; do sleep 1; done
/usr/bin/time -v -o create50.time "$G" create -d -k 31 -l 20 -s 60000 -b 50 -t 16 -o rehearsal50.agc "$REF" $(sed 's|.*|in/&.fa|' names50.txt)
wait $FP
sha256sum rehearsal50.agc "$OLD" | sed "s|$HOME/pubrepo/.wk/||"
ls -l rehearsal50.agc "$OLD" | awk '{print $5, $9}'
grep -E "Elapsed|Maximum resident" create50.time
