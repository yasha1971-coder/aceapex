#!/bin/bash
# CRASH-3d runner: binary $1, label $2, out $3, extra env $4 (e.g. AX_HUGE=0). silesia.tar and enwik9; aceapex 1-4 and
# aceapex-fast 1, 8; t1 and t4; each codec/level/threads its own process; -C4 -v2 -U (memory columns where counted).
TB=$1; LBL=$2; OUT=$3; XENV=$4; mkdir -p $OUT
S=$OUT/summary.tsv; printf 'build\tfile\tcodec\tt\trc\tsignal\tC_MB/s\tD_MB/s\tC_MEM\tD_MEM\tratio\n' > $S
for f in silesia.tar enwik9; do for t in 1 4; do for e in aceapex,1 aceapex,2 aceapex,3 aceapex,4 aceapex-fast,1 aceapex-fast,8; do
  E=$e; [ $t != 1 ] && E="$e:t$t"
  D=$OUT/$f-${e/,/-}-t$t; mkdir -p $D; cd $D; ln -sf $GITHUB_WORKSPACE/in/$f $f
  echo "${XENV:+env $XENV }$TB $f -C4 -v2 -U -e$E" > cmd.txt
  timeout -s KILL 900 env $XENV $TB $f -C4 -v2 -U -e$E > stdout.txt 2> stderr.txt; rc=$?   # 900 s cap: a run that hangs is a result (C run 1 hung for hours)
  sig=-; [ $rc -gt 128 ] && sig="$((rc-128)) $(kill -l $((rc-128)))"; [ $rc = 137 ] && sig="9 KILL (timeout 900 s: hang)"
  name="${e/,/ }"; [ $t != 1 ] && name="$name:t$t"
  row=$(sed 's/\x1b\[[0-9;]*m//g' stdout.txt | grep -E " $name +$f\$" | tail -1)
  # final table row: C_size ratio% C_MB/s D_MB/s rank C_MEM D_MEM C_STACK D_STACK name file
  set -- $row
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$LBL" $f "$e" $t $rc "$sig" "${3:--}" "${4:--}" "${6:--}" "${7:--}" "${2:--}" >> $S
  echo "$LBL $f $E: rc $rc $sig"
  rm -f $f; cd $OUT
done; done; done
