#!/bin/bash
# CRASH-2 steps 2-4: one named systemd user scope per run, MemoryMax=LIMIT, MemorySwapMax=0.
# usage: limited.sh LIMIT CODEC LEVEL T RUN
L=$1; c=$2; l=$3; t=$4; k=$5
TB=/tmp/crash1/tb164/turbobench-linux-x86_64/turbobench; f=enwik9
E="$c,$l"; [ $t -gt 1 ] && E="$c,$l:t$t"
U=crash2-$c-$l-t$t-$L-r$k; D=/tmp/crash2/lim/$U; mkdir -p $D; cd $D; ln -sf /home/aeterna/golden/text/enwik9 $f
until awk "BEGIN{exit !($(cut -d' ' -f1 /proc/loadavg)<1.0)}"; do sleep 5; done
CMD="systemd-run --user --scope -u $U -p MemoryMax=$L -p MemorySwapMax=0 bash -c '...'"
echo "cmd: systemd-run --user --scope -u $U -p MemoryMax=$L -p MemorySwapMax=0 /usr/bin/time -v $TB $f -C4 -v2 -U -e$E" > cmd.txt
systemd-run --user --scope -u $U -p MemoryMax=$L -p MemorySwapMax=0 bash -c '
  cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)
  echo "memory.max $(cat $cg/memory.max) memory.swap.max $(cat $cg/memory.swap.max)" > limits.txt
  /usr/bin/time -v -o time.txt '"$TB $f -C4 -v2 -U -e$E"' > stdout.txt 2> stderr.txt; echo $? > rc.txt
  cp $cg/memory.events memory.events; cp $cg/memory.events.local memory.events.local 2>/dev/null; cat $cg/memory.peak > memory.peak 2>/dev/null' 2> scope.err
src=$?
journalctl --user -u $U.scope --no-pager -o short-iso > journal.txt 2>&1
rc=$(cat rc.txt 2>/dev/null || echo "none(scope rc $src)")
sig=""; [[ $rc =~ ^[0-9]+$ ]] && [ $rc -gt 128 ] && sig=" signal $((rc-128)) $(kill -l $((rc-128)))"
rss=$(grep "Maximum resident" time.txt 2>/dev/null | awk '{print $NF}')
oom=$(grep -E "^oom " memory.events 2>/dev/null | awk '{print $2}'); kill=$(grep -E "^oom_kill " memory.events 2>/dev/null | awk '{print $2}')
ok=$(sed 's/\x1b\[[0-9;]*m//g' stdout.txt 2>/dev/null | grep -c -E "^ +[0-9]+ +[0-9.]+% .*$c ")
c4=$([ "$rc" = 0 ] && [ "$ok" -ge 1 ] && echo pass || echo FAIL)
printf '%s\t%s\t%s\tt%s\tr%s\t%s%s\t%s\toom %s oom_kill %s\t%s\t%s\n' $L $c $l $t $k "$rc" "$sig" "${rss:-n/a}" "${oom:-?}" "${kill:-?}" $c4 "$(cat limits.txt 2>/dev/null)" | tee -a /tmp/crash2/lim/summary.tsv
rm -f $f
