#!/usr/bin/env bash
# truth_all.sh <hprc50 dir> <manifest_v1.tsv> <req dir> <out dir> - per sample: sha256 of <sample>.fa.gz == manifest
# source_sha256, then gzip -dc | truth <sample> <requests>; 8 samples at a time
set -euo pipefail
ulimit -c 0   # no core dumps from test runs
SRC=$1; MAN=$2; REQ=$3; OUT=$4; BIN=$(dirname "$0")
mkdir -p "$OUT"
awk -F'\t' 'NR>1 && NR<=51{sub(/^y1_/,"",$1); print $1"\t"$4}' "$MAN" | xargs -P 8 -L 1 bash -c '
  s=$0; want=$1
  have=$(sha256sum "'"$SRC"'/$s.fa.gz" | cut -d" " -f1)
  [ "$have" = "$want" ] || { echo "SHAFAIL $s"; exit 1; }
  gzip -dc "'"$SRC"'/$s.fa.gz" | "'"$TRUTH"'" "$s" "'"$REQ"'/windows_8192.tsv" "'"$REQ"'/regions.tsv" > "'"$OUT"'/$s.truth.tsv"
  echo "ok $s"'
