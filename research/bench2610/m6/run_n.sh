#!/usr/bin/env bash
# run_n.sh <N> <phase> [check] - PROTOCOL_M6 per N. Work dir ~/pubrepo/.wk/m6/N<N>; evidence in m6/logs/N<N>/.
# phases: req (requests + truth), create, integrity, h5 (gdb stack + fast), counters, measure, perf, all.
# "check" = method check of section 3 (1 warm-up + 1 timed run, 100 counted windows, perf over 100 windows).
set -uo pipefail
ulimit -c 0
N=$1; PH=$2; CHK=${3:-}
D=$(cd "$(dirname "$0")" && pwd); L=$D/logs/N$N; W=$HOME/pubrepo/.wk/m6/N$N; mkdir -p $L $W/in
B=$HOME/pubrepo/.wk/avr; G=$HOME/pubrepo/.wk/tools/agc-src/bin/agc; REF=$HOME/golden/genome/t2t.fa; V1=$HOME/pubrepo/.wk/hprc_cohort/v1
CNT=$HOME/pubrepo/.wk/agccount/agccount; PROF=$HOME/pubrepo/.wk/agcprof/agcbench_fp; PY=$HOME/panvram/.venv/bin/python
ARC=$W/agc$N.agc; [ "$N" = 558 ] && ARC=$HOME/pubrepo/.wk/agc558/agc558.agc
WIN=$W/windows_4096.tsv; REG=$W/regions_1M.tsv; TR=$W/truth.tsv; export AVR_NAMES=$W/names.tsv
WU=3; R=9; NC=1000; [ "$CHK" = check ] && { WU=1; R=1; NC=100; }
gate() { until awk '{exit !($1<0.5)}' /proc/loadavg; do sleep 10; done
  { echo "# silence gate $1 $(date -u +%FT%TZ)"; echo "loadavg: $(cat /proc/loadavg)"; echo "df: $(df -h / | tail -1 | awk '{print $4" free of "$2}')"; echo "mem: $(free -g | awk '/Mem:/{print $7" GB available of "$2}')"
    echo "top processes by CPU:"; ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu | head -8; } > $L/silence_$1.txt; }
run() { local label=$1 T=$2; shift 2; local pin=(); [ "$T" = 1 ] && pin=(taskset -c 3)
  { echo "# $label start $(date -u +%FT%TZ) loadavg $(cat /proc/loadavg)"; /usr/bin/time -v "${pin[@]}" "$@"; echo "# exit $? end $(date -u +%FT%TZ) loadavg $(cat /proc/loadavg)"; } > $L/$label.log 2>&1
  grep -E "^RUN.*timed|Maximum resident" $L/$label.log | tail -2 | sed "s/^/$label: /"; }
case $PH in
req|all)
  $PY $D/make_req.py $N $W > $L/req.log 2>&1 && cat $L/req.log
  $B/truth_v1 $REF $V1 $W/names.tsv $WIN $REG > $TR 2> $L/truth.err; echo "truth exit $?"
  sha256sum $WIN $REG $W/names.tsv $W/samples4.txt $TR | sed "s|$W/||" | tee $L/inputs.sha256 ;;&
create|all)
  [ "$N" = 558 ] || { cut -f1 $W/names.tsv > $W/names.txt
    "$B/fifo_feed" "$REF" "$V1" q16k "$W/in" 4 $(cat $W/names.txt) 2> $L/feed.log & FP=$!
    until [ "$(find $W/in -type p | wc -l)" = $N ]; do sleep 1; done
    /usr/bin/time -v -o $L/create.time "$G" create -d -k 31 -l 20 -s 60000 -b 50 -t 16 -o $ARC "$REF" $(sed "s|.*|$W/in/&.fa|" $W/names.txt) 2> $L/create.err
    wait $FP; echo "feed exit $?"; grep -E "Elapsed|Maximum resident|Exit status" $L/create.time; }
  { stat -c '%s %n' $ARC; sha256sum $ARC; } | sed "s|$HOME/pubrepo/||" | tee $L/archive.txt ;;&
integrity|all)
  { echo t2t; cut -f1 $W/names.tsv; } | sort > $W/want_sets.txt; "$G" listset "$ARC" | sort > $W/have_sets.txt
  if cmp -s $W/want_sets.txt $W/have_sets.txt; then echo "LISTSET ok: t2t + $N" > $L/integrity.txt; else echo "LISTSET FAIL" | tee $L/integrity.txt; exit 1; fi
  bad=0; while IFS=$'\t' read -r n _; do awk -F'\t' -v s="$n" '$1=="CTG" && $2==s{print $3}' $TR > $W/cw.txt
    "$G" listctg "$ARC" "$n" | tail -n +2 | sed 's/^ *//' > $W/ch.txt; if cmp -s $W/cw.txt $W/ch.txt; then r=ok; else r=FAIL; bad=$((bad+1)); fi
    printf '%s\t%s\t%s\t%s\n' "$n" $(wc -l < $W/cw.txt) $(wc -l < $W/ch.txt) $r >> $L/integrity.txt; done < $W/names.tsv
  echo "SETS $N, listset ok, listctg failures: $bad" | tee -a $L/integrity.txt; [ $bad = 0 ] || exit 1 ;;&
h5|all)
  head -2 $WIN > $W/one.tsv
  gdb -batch -ex "break CAGCDecompressorLibrary::decompress_contig" -ex run -ex bt -ex "info args" -ex kill --args $CNT $ARC $W/one.tsv $TR $W/h5 > $L/h5_gdb.txt 2>&1
  grep -E "^#[0-9]|^fast" $L/h5_gdb.txt | head -12 ;;&
counters|all)
  head -$((NC + 1)) $WIN > $W/cnt_win.tsv
  { head -1 $W/cnt_win.tsv; tail -n +2 $W/cnt_win.tsv | awk -F'\t' 'NR==FNR{o[$1]=NR; next} {print o[$2]"\t"$0}' $W/names.tsv - | sort -t$'\t' -k1,1n -k4,4 -k5,5n | cut -f2-; } > $W/cnt_win_sorted.tsv
  : > $L/counters.txt
  for x in cnt_win cnt_win_sorted; do $CNT $ARC $W/$x.tsv $TR $L/$x | tee -a $L/counters.txt; done
  $CNT $ARC $REG $TR $L/cnt_reg | tee -a $L/counters.txt ;;&
measure|all)
  gate measure
  S4=$(cat $W/samples4.txt)
  for T in 1 16; do
    for ds in q4k q16k; do
      run rr3_${ds}_win_t$T $T $B/rr3bench req $REF $V1 $ds $WIN $TR $T $WU $R rr3_${ds}_win_t$T
      run rr3_${ds}_reg_t$T $T $B/rr3bench req $REF $V1 $ds $REG $TR $T $WU $R rr3_${ds}_reg_t$T
      run rr3_${ds}_s4_t$T $T $B/rr3bench sample $REF $V1 $ds $S4 $TR $T $WU $R rr3_${ds}_s4_t$T
    done
    run agc_win_t$T $T $B/agcbench req $ARC $WIN $TR $T $WU $R agc_win_t$T
    run agc_reg_t$T $T $B/agcbench req $ARC $REG $TR $T $WU $R agc_reg_t$T
    run agc_s4_t$T $T $B/agcbench sample $ARC $S4 $TR $T $WU $R agc_s4_t$T
  done ;;&
perf|all)
  gate perf
  PW=10000; [ "$CHK" = check ] && PW=1000
  head -$((PW + 1)) $WIN > $W/perf_win.tsv
  perf record -e cycles:u -g --call-graph fp -o $W/perf.data -- taskset -c 3 $PROF req $ARC $W/perf_win.tsv $TR 1 0 1 perf_N$N > $L/perf_run.log 2>&1
  perf report -i $W/perf.data --stdio --no-children --sort symbol --parent agc_get_ctg_seq -x 2>/dev/null | grep -v "^$" | head -600 > $L/perf_self.txt
  perf report -i $W/perf.data --stdio --children --sort symbol --parent agc_get_ctg_seq -x 2>/dev/null | grep -v "^$" | head -600 > $L/perf_children.txt
  perf report -i $W/perf.data --stdio --no-children --sort parent --parent agc_get_ctg_seq 2>/dev/null | grep -E "^ +[0-9.]+%" > $L/perf_parent_share.txt
  grep -E "^RUN" $L/perf_run.log; cat $L/perf_parent_share.txt; grep -E "^ +[0-9.]+%" $L/perf_self.txt | head -8 | cut -c1-120 ;;
esac
