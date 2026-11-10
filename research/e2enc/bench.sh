#!/bin/bash
# E2-ENC measurement (TASK_E2-ENC.md, 10.11.2026), the same at every step. ace-core, one physical core (taskset -c $CPU),
# load1 < 0.5 before every run, N runs, median. Per corpus and level: archive (aceapex c --threads 1) -> size, sha256;
# ratio = size / original; compression and decompression MB/s from `aceapex t --threads 1` (decode = median of 7 inside).
# Judge: our decoder round trip of every archive (sha256 of the output == original) and the v2.6.1 release binary
# (82e62e56..., from aceapex-2.6.1-linux-x86_64.tar.gz 34705ace...) decoding every archive of levels 12-14 the same way.
# Usage: bash research/e2enc/bench.sh <step> <outdir> [levels] [runs] [corpora...]
#   defaults: levels "12 13 14", runs 5, corpora silesia.tar enwik8 chr1 (dev). Writes <outdir>/<step>.tsv and judge.tsv.
set -euo pipefail
STEP=$1; OUT=$2; LEVELS=${3:-"12 13 14"}; RUNS=${4:-5}; shift $(( $# < 4 ? $# : 4 ))
CORP=("$@"); [ ${#CORP[@]} -gt 0 ] || CORP=(/tmp/hwref/corpus/silesia.tar /home/aeterna/golden/text/enwik8 /home/aeterna/golden/genome/chr1.fa)
BIN=${BIN:-./aceapex}; REL=${REL:-/home/aeterna/pubrepo/.wk/e2work/rel261/aceapex-2.6.1-linux-x86_64/aceapex}
CPU=${CPU:-2}; TMP=${TMP:-/home/aeterna/pubrepo/.wk/e2work/tmp}
mkdir -p "$OUT" "$TMP"
[ "$(sha256sum "$REL" | cut -c1-16)" = 82e62e5697af5e3b ] || { echo "STOP: v2.6.1 binary sha256"; exit 2; }
quiet() { local n=0; until awk "BEGIN{exit !($(cut -d' ' -f1 /proc/loadavg)<0.5)}"; do sleep 10; n=$((n + 1)); [ $n -gt 180 ] && { echo "WARN load1 >= 0.5 for 30 min" >&2; break; }; done; return 0; }
T="$OUT/$STEP.tsv"; J="$OUT/judge.tsv"
[ -f "$T" ] || echo -e "step\tcorpus\tlevel\trun\tsize\tratio_pct\tc_mbs\td_mbs\tarchive_sha256" > "$T"
[ -f "$J" ] || echo -e "step\tcorpus\tlevel\tours\tv2.6.1" > "$J"
STATUS=${STATUS:-/home/aeterna/pubrepo/.wk/e2work/STATUS}
st() { echo "$(date -u +%FT%TZ) $STEP $*" >> "$STATUS"; }
# resume: a (corpus, level) with RUNS rows (or the run-0 row when RUNS=0) is done; partial rows of a pair are dropped
have() { awk -F'\t' -v s="$STEP" -v c="$1" -v l="$2" '$1==s && $2==c && $3==l' "$T" | wc -l; }
drop() { awk -F'\t' -v s="$STEP" -v c="$1" -v l="$2" '!($1==s && $2==c && $3==l)' "$T" > "$T.tmp" && mv "$T.tmp" "$T"; }
st "start levels=[$LEVELS] runs=$RUNS"
for f in "${CORP[@]}"; do
  c=$(basename "$f"); osz=$(stat -c %s "$f"); osha=$(sha256sum "$f" | cut -d' ' -f1)
  for L in $LEVELS; do
    need=$(( RUNS > 0 ? RUNS : 1 )); h=$(have "$c" "$L")
    [ "$h" -ge "$need" ] && continue
    [ "$h" -gt 0 ] && drop "$c" "$L"
    st "$c L$L"
    a="$TMP/$c.L$L.aet"
    taskset -c "$CPU" "$BIN" c --in "$f" --out "$a" --threads 1 --level "$L" > /dev/null 2>&1
    sz=$(stat -c %s "$a"); ash=$(sha256sum "$a" | cut -d' ' -f1)
    "$BIN" d --in "$a" --out "$TMP/rt" > /dev/null 2>&1; ours=$([ "$(sha256sum "$TMP/rt" | cut -d' ' -f1)" = "$osha" ] && echo ok || echo FAIL)
    rel=-; if [ "$L" -ge 12 ] && [ "$L" -le 14 ]; then "$REL" d --in "$a" --out "$TMP/rt" > /dev/null 2>&1 || true
      rel=$([ "$(sha256sum "$TMP/rt" | cut -d' ' -f1)" = "$osha" ] && echo ok || echo FAIL); fi
    rm -f "$TMP/rt"; echo -e "$STEP\t$c\t$L\t$ours\t$rel" >> "$J"
    { [ "$ours" = ok ] && [ "$rel" != FAIL ]; } || { echo "STOP: judge $c L$L ours=$ours v2.6.1=$rel"; exit 3; }
    [ "$RUNS" = 0 ] && echo -e "$STEP\t$c\t$L\t0\t$sz\t$(awk "BEGIN{printf \"%.3f\", 100*$sz/$osz}")\t\t\t$ash" >> "$T"
    for r in $(seq 1 "$RUNS"); do
      quiet
      o=$(taskset -c "$CPU" "$BIN" t --in "$f" --threads 1 --level "$L" 2>&1)
      echo "$o" | grep -q 'BIT-PERFECT' || { echo "STOP: t-mode not bit-perfect $c L$L"; exit 3; }
      cm=$(echo "$o" | awk '/Encode:/{print $2}'); dm=$(echo "$o" | awk '/Decode:/{print $2}')
      echo -e "$STEP\t$c\t$L\t$r\t$sz\t$(awk "BEGIN{printf \"%.3f\", 100*$sz/$osz}")\t$cm\t$dm\t$ash" >> "$T"
    done
    rm -f "$a"
  done
done
st "done"; echo "done $STEP $(date -u +%FT%TZ)"
