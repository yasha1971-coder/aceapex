#!/usr/bin/env bash
# REL261 32-bit x86 gate: archive of the 32-bit build (same32) == 64-bit 2.6.0 (same_base); then round trips of the 32-bit build
G=~/golden; n=0; bad=0
for X in $G/mixed/silesia.tar $G/text/enwik8; do for LV in 1 2 3 11 12 13 14 15 16 17 18; do for T in 1 4; do
  r=$(~/enc6/same_base $X $LV $T | sha256sum | cut -c1-16); v=$(/tmp/m32/same32 $X $LV $T | sha256sum | cut -c1-16)
  [ "$r" = "$v" ] && s=same || { s=DIFF; bad=$((bad+1)); }; n=$((n+1)); echo "$(basename $X) L$LV T$T 64-bit-2.6.0 $r 32-bit-2.6.1 $v $s"
done; done; done
echo "# $n archives, DIFF $bad"
for f in /tmp/be/e0 /tmp/be/e1 /tmp/be/e100 /tmp/be/e1m5 /tmp/be/erand /tmp/be/edna /tmp/be/silesia.64k; do echo "== $(basename $f)"; /tmp/m32/rt32 $f 1 2 3 11 12 13 14 15 16 17 18; done
