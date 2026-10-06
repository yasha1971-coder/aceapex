#!/usr/bin/env bash
# repro.sh <agc binary> <archive.agc> - AGC 3.2.4: two sets of an append-built archive hold only some of their contigs.
# For each of the two sets: the contigs AGC lists, the contig count of the source FASTA, one contig AGC has (answered)
# and one it lacks (error). Output: repro_output.txt (committed next to this script).
set -euo pipefail
ulimit -c 0
AGC=$1; ARC=$2
{ "$AGC" 2>&1 || true; } | head -1 || true
echo "archive: $(basename "$ARC") $(stat -c%s "$ARC") B, sets: $("$AGC" listset "$ARC" | wc -l)"
for s in r2_NA19682_hap2_hprc_r2_v1.0.1 r2_HG01175_mat_hprc_r2_v1.0.1; do
  echo "== set $s"
  echo "AGC listctg:"; "$AGC" listctg "$ARC" "$s"
  echo "source FASTA contigs: $(wc -l < $(dirname "$0")/$s.source_contigs.tsv)"
  have=$("$AGC" listctg "$ARC" "$s" | sed -n 2p | tr -d ' ')
  lack=$(cut -f1 $(dirname "$0")/$s.source_contigs.tsv | grep -v -F -x -f <("$AGC" listctg "$ARC" "$s" | tail -n +2 | tr -d ' ') | head -1)
  echo "getctg present contig $have@$s:0-59"; "$AGC" getctg "$ARC" "$have@$s:0-59"
  echo "getctg missing contig $lack@$s:0-59 (exit code follows)"; rc=0; "$AGC" getctg "$ARC" "$lack@$s:0-59" 2>&1 || rc=$?; echo "exit $rc"
done
