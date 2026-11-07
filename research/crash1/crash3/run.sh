#!/bin/bash
# CRASH-3 runner (inside the job): TurboBench binary $1, label $2, output dir $3.
# Base: silesia.tar, each aceapex level in its own process, no t#, twice; enwik9 the same if silesia passed.
# Then t2 and t4 separately, twice, both files; then one -f3 run per level on silesia.
TB=$1; LBL=$2; OUT=$3; mkdir -p $OUT
S=$OUT/summary.tsv; printf 'binary\tfile\tlevel\tt\tflags\trun\trc\tsignal\tlast_stage\n' > $S
one() { # file level t extra run
  f=$1; l=$2; t=$3; x=$4; k=$5
  E="aceapex,$l"; [ "$t" != 1 ] && E="aceapex,$l:t$t"
  D=$OUT/$f-L$l-t$t${x:+-f3}-r$k; mkdir -p $D; cd $D; ln -sf $GITHUB_WORKSPACE/in/$f $f
  echo "$TB $f -C4 -v2 $x -e$E" > cmd.txt
  ( ulimit -c unlimited; $TB $f -C4 -v2 $x -e$E > stdout.txt 2> stderr.txt ); rc=$?
  sig=""; [ $rc -gt 128 ] && sig="$((rc-128)) $(kill -l $((rc-128)))"
  stage=$(sed 's/\x1b\[[0-9;]*m//g' stdout.txt | grep -E "aceapex" | tail -1 | tr -s ' ' | cut -c1-120)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$LBL" $f $l $t "${x:--}" $k $rc "${sig:--}" "${stage:--}" >> $S
  echo "$LBL $f L$l t$t ${x:-} r$k: rc $rc ${sig}"
  rm -f $f; cd $OUT
  return $rc
}
fail=0
for l in 1 2 3 4; do for k in 1 2; do one silesia.tar $l 1 "" $k || fail=1; done; done
if [ $fail = 0 ]; then for l in 1 2 3 4; do for k in 1 2; do one enwik9 $l 1 "" $k || fail=1; done; done; fi
for t in 2 4; do for f in silesia.tar enwik9; do for l in 1 2 3 4; do for k in 1 2; do one $f $l $t "" $k || fail=1; done; done; done; done
for l in 1 2 3 4; do one silesia.tar $l 1 "-f3" 1 || fail=1; done
echo "fail=$fail"
