#!/bin/bash
# E2-ENC test (once) and final decode check, detached; progress in $W/STATUS. Test corpora are read in place (VIKA: internal
# numbers only). Base = S0 binary, new = S6 binary; the v2.6.1 judge covers levels 12-18.
#   1) test: enwik9, VIKA - levels 11-14 x5, 15-16 x1 timed, 17-18 archive only (sha256 vs S0) - for both binaries
#   2) final: dev corpora, levels 12-14, 9 runs interleaved S0 / S6 (t-mode decode median of 7 inside each run)
set -euo pipefail
W=/home/aeterna/pubrepo/.wk/e2work; cd /home/aeterna/pubrepo/.wk/e2enc
TEST=(/home/aeterna/golden/text/enwik9 /home/aeterna/Aeterna_Core_Final/VIKA_proekt_raw.tar)
export REL_MAX=18
for b in S0 S6; do
  BIN=$W/bin/$b bash research/e2enc/bench.sh "T_$b" "$W/res" "11 12 13 14" 5 "${TEST[@]}"
  BIN=$W/bin/$b bash research/e2enc/bench.sh "T_$b" "$W/res" "15 16" 1 "${TEST[@]}"
  BIN=$W/bin/$b bash research/e2enc/bench.sh "T_$b" "$W/res" "17 18" 0 "${TEST[@]}"
done
echo "$(date -u +%FT%TZ) TEST DONE" >> "$W/STATUS"
DEV=(/tmp/hwref/corpus/silesia.tar /home/aeterna/golden/text/enwik8 /home/aeterna/golden/genome/chr1.fa)
FT=$W/res/final.tsv; [ -f "$FT" ] || echo -e "round\tbin\tcorpus\tlevel\td_mbs\tc_mbs" > "$FT"
quiet() { until awk "BEGIN{exit !($(cut -d' ' -f1 /proc/loadavg)<0.5)}"; do sleep 10; done; }
for r in 1 2 3 4 5 6 7 8 9; do
  for f in "${DEV[@]}"; do for L in 12 13 14; do for b in S0 S6; do
    grep -q "^$r	$b	$(basename "$f")	$L	" "$FT" && continue
    quiet; o=$(taskset -c 2 "$W/bin/$b" t --in "$f" --threads 1 --level "$L" 2>&1)
    echo -e "$r\t$b\t$(basename "$f")\t$L\t$(echo "$o" | awk '/Decode:/{print $2}')\t$(echo "$o" | awk '/Encode:/{print $2}')" >> "$FT"
  done; done; done
  echo "$(date -u +%FT%TZ) final round $r" >> "$W/STATUS"
done
echo "$(date -u +%FT%TZ) FINAL DONE" >> "$W/STATUS"
