#!/usr/bin/env bash
# integrity.sh - PROTOCOL_AGC558 section 2 integrity before any timing: (1) agc listset == t2t + the 558 manifest names;
# (2) agc listctg of every set == the contig names of its FASTA in order (truth558 CTG lines, which come from the v1
# decode with the source XXH3 check); (3) agc getset -l <80 year-1 | 60 release 2> -> XXH3 == the manifest's fasta_xxh3.
# One line per set in integrity558.tsv; summary at the end. Exit 0 only if all pass.
set -euo pipefail
ulimit -c 0
W=$HOME/pubrepo/.wk/agc558; G=$HOME/pubrepo/.wk/tools/agc-src/bin/agc; ARC=$W/agc558.agc; X=$HOME/pubrepo/.wk/avr/xxh3_stdin
MAN=$HOME/pubrepo/.wk/hprc_cohort/v1/manifest_v1.tsv; TR=$HOME/pubrepo/.wk/avr/truth558.tsv; MAP=$HOME/pubrepo/.wk/avr/agc558_names.tsv
OUT=$(cd "$(dirname "$0")" && pwd)/integrity558.tsv
{ echo t2t; awk -F'\t' 'NR>1{print $1}' $MAN; } | sort > $W/want_sets.txt
"$G" listset "$ARC" | sort > $W/have_sets.txt
if cmp -s $W/want_sets.txt $W/have_sets.txt; then echo "LISTSET ok: t2t + 558"; else echo "LISTSET FAIL"; diff $W/want_sets.txt $W/have_sets.txt | head; exit 1; fi
printf 'name\tcontigs_fasta\tcontigs_agc\tlistctg\tline_width\txxh3_getset\txxh3_manifest\tgetset\n' > $OUT
bad=0
while IFS=$'\t' read -r name old; do
  awk -F'\t' -v s="$old" '$1=="CTG" && $2==s{print $3}' $TR > $W/ctg_want.txt
  "$G" listctg "$ARC" "$name" | tail -n +2 | sed 's/^ *//' > $W/ctg_have.txt
  lc=ok; cmp -s $W/ctg_want.txt $W/ctg_have.txt || lc=FAIL
  case $name in y1_*) lw=80;; *) lw=60;; esac
  h=$("$G" getset -t 16 -l $lw "$ARC" "$name" | "$X")
  m=$(awk -F'\t' -v n="$name" '$1==n{print $6}' $MAN)
  gs=ok; [ "$h" = "$m" ] || gs=FAIL
  [ $lc = ok ] && [ $gs = ok ] || bad=$((bad + 1))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" $(wc -l < $W/ctg_want.txt) $(wc -l < $W/ctg_have.txt) $lc $lw "$h" "$m" $gs >> $OUT
done < $MAP
echo "SETS 558, listctg+getset failures: $bad"
[ $bad = 0 ]
