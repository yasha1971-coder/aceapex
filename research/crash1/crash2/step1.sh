#!/bin/bash
# CRASH-2 step 1: unconstrained, official TurboBench v2026.11.06.164 (aceapex b67c858), one process per codec/level/threads
TB=/tmp/crash1/tb164/turbobench-linux-x86_64/turbobench
OUT=/tmp/crash2/step1; mkdir -p $OUT
printf 'file\tcodec\tlevel\tt\trc\tmaxrss_kib\tC4\twall\n' > $OUT/summary.tsv
for f in silesia.tar enwik9; do
  src=/tmp/hwref/corpus/silesia.tar; [ $f = enwik9 ] && src=/home/aeterna/golden/text/enwik9
  for spec in "aceapex 1 1" "aceapex 2 1" "aceapex 3 1" "aceapex 4 1" "aceapex 1 4" "aceapex 2 4" "aceapex 3 4" "aceapex 4 4" "aceapex_fast 1 1" "aceapex_fast 1 4"; do
    set -- $spec; c=$1; l=$2; t=$3
    E="$c,$l"; [ $t -gt 1 ] && E="$c,$l:t$t"
    D=$OUT/$f-$c-$l-t$t; mkdir -p $D; cd $D; ln -sf $src $f
    until awk "BEGIN{exit !($(cut -d' ' -f1 /proc/loadavg)<1.0)}"; do sleep 10; done
    echo "cmd: /usr/bin/time -v $TB $f -C4 -v2 -U -e$E" > cmd.txt
    /usr/bin/time -v -o time.txt $TB $f -C4 -v2 -U -e$E > stdout.txt 2> stderr.txt; rc=$?
    rss=$(grep "Maximum resident" time.txt | awk '{print $NF}'); wall=$(grep "Elapsed (wall" time.txt | awk '{print $NF}')
    ok=$(sed 's/\x1b\[[0-9;]*m//g' stdout.txt | grep -c -E "^ +[0-9]+ +[0-9.]+% .*$c ")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' $f $c $l $t $rc $rss $([ $rc = 0 ] && [ $ok -ge 1 ] && echo pass || echo FAIL) $wall >> $OUT/summary.tsv
    rm -f $f
  done
done
echo ALLDONE
