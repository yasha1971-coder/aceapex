#!/usr/bin/env bash
# REL261 byte gate on x86: archives of 2.6.1 (same_261) == 2.6.0 (same_base), silesia/enwik8/chr1 x L1-3, L11-18 x T1/T4
G=~/golden; n=0; bad=0
for X in $G/mixed/silesia.tar $G/text/enwik8 $G/genome/chr1.fa; do for LV in 1 2 3 11 12 13 14 15 16 17 18; do for T in 1 4; do
  r=$(~/enc6/same_base $X $LV $T | sha256sum | cut -c1-16); v=$(/tmp/same_261 $X $LV $T | sha256sum | cut -c1-16)
  [ "$r" = "$v" ] && s=same || { s=DIFF; bad=$((bad+1)); }; n=$((n+1)); echo "$(basename $X) L$LV T$T 2.6.0 $r 2.6.1 $v $s"
done; done; done
echo "# $n archives, DIFF $bad"
