#!/bin/bash
# E2-ENC, after the test and the final decode check (Yakiv 11.11): (1) enwik9 tail - bytes [10^8, 10^9) (enwik8 = the first 10^8
# bytes of enwik9 was dev), levels 11-16, S0 and S6 (17-18 bytes = S0 by construction); (2) lzbench 987a6bd, bundled aceapex 2.6.1
# (base) and the branch (S6), silesia a667bac8, 1 thread whole file and -b4096 -T8. Progress in $W/STATUS.
set -euo pipefail
W=/home/aeterna/pubrepo/.wk/e2work; cd /home/aeterna/pubrepo/.wk/e2enc
T=$W/test/enwik9_tail
if [ ! -f "$T" ]; then tail -c +100000001 /home/aeterna/golden/text/enwik9 > "$T.tmp" && mv "$T.tmp" "$T"; fi
echo "$(date -u +%FT%TZ) tail $(stat -c %s "$T") B sha256 $(sha256sum "$T" | cut -d' ' -f1)" >> "$W/STATUS"
export REL_MAX=18
for b in S0 S6; do
  BIN=$W/bin/$b bash research/e2enc/bench.sh "TT_$b" "$W/res" "11 12 13 14" 5 "$T"
  BIN=$W/bin/$b bash research/e2enc/bench.sh "TT_$b" "$W/res" "15 16" 1 "$T"
done
echo "$(date -u +%FT%TZ) TAIL DONE" >> "$W/STATUS"

# lzbench: two trees from one clone at 987a6bd; base keeps the bundled aceapex 2.6.1, e2 gets the branch via lzbench_sync.sh
L=$W/lzb; mkdir -p "$L"
[ -d "$L/base" ] || git clone -q https://github.com/inikep/lzbench.git "$L/base"
( cd "$L/base" && git checkout -q 987a6bd )
[ -d "$L/e2" ] || cp -r "$L/base" "$L/e2"
bash scripts/lzbench_sync.sh "$L/e2" > "$L/sync.log" 2>&1
for t in base e2; do ( cd "$L/$t" && [ -x lzbench ] || make BUILD_ONLY="ACEAPEX ZXC MISA77 LIZARD LZAV" -j8 > "$L/build-$t.log" 2>&1 ); done
F=/tmp/hwref/corpus/silesia.tar; E='aceapex_fast,1,2,3,4,8/zxc,1,3/misa77,0,1/lizard,12/lzav,1'
quiet() { until awk "BEGIN{exit !($(cut -d' ' -f1 /proc/loadavg)<0.5)}"; do sleep 15; done; }
{ echo "lzbench $(git -C "$L/base" rev-parse HEAD); silesia $(sha256sum "$F" | cut -c1-16); $(gcc -dumpfullversion)"
  for t in base e2; do
    quiet; echo "### $t whole 1t | load $(cut -d' ' -f1-3 /proc/loadavg) | taskset -c 2 -t8,8 -o4 -e$E"; taskset -c 2 "$L/$t/lzbench" -t8,8 -o4 -e"$E" "$F" 2>&1
    quiet; echo "### $t b4096 T8 | load $(cut -d' ' -f1-3 /proc/loadavg) | taskset -c 0-7 -t8,8 -o4 -b4096 -T8 -e$E"; taskset -c 0-7 "$L/$t/lzbench" -t8,8 -o4 -b4096 -T8 -e"$E" "$F" 2>&1
  done; } > "$W/res/lzbench-e2-2026-11-11.log"
echo "$(date -u +%FT%TZ) LZBENCH DONE" >> "$W/STATUS"
