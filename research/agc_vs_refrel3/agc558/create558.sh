#!/usr/bin/env bash
# create558.sh - PROTOCOL_AGC558 section 2: one agc create on the 558 manifest assemblies through FIFOs (manifest order and
# names), and T2T alone; /usr/bin/time -v for both.
set -euo pipefail
ulimit -c 0
W=$HOME/pubrepo/.wk/agc558; mkdir -p $W/in; cd $W
G=$HOME/pubrepo/.wk/tools/agc-src/bin/agc; REF=$HOME/golden/genome/t2t.fa
awk -F'\t' 'NR>1{print $1}' $HOME/pubrepo/.wk/hprc_cohort/v1/manifest_v1.tsv > names558.txt
[ "$(wc -l < names558.txt)" = 558 ]
"$G" create -d -k 31 -l 20 -s 60000 -b 50 -t 16 -o t2t_alone.agc "$REF" 2> t2t_alone.err
"$HOME/pubrepo/.wk/avr/fifo_feed" "$REF" "$HOME/pubrepo/.wk/hprc_cohort/v1" q16k "$W/in" 4 $(cat names558.txt) 2> feed558.log & FP=$!
until [ "$(find in -type p | wc -l)" = 558 ]; do sleep 1; done
/usr/bin/time -v -o create558.time "$G" create -d -k 31 -l 20 -s 60000 -b 50 -t 16 -o agc558.agc "$REF" $(sed 's|.*|in/&.fa|' names558.txt)
wait $FP
sha256sum agc558.agc t2t_alone.agc
ls -l agc558.agc t2t_alone.agc | awk '{print $5, $9}'
grep -E "Elapsed|Maximum resident|Exit status" create558.time
