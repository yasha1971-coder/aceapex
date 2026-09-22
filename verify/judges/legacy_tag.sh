#!/usr/bin/env bash
# Judge for tags that predate the contract (v2.0, v3.0, v4.0). Runs inside the tag worktree.
# R claims judged here: the tag builds; its own binary round-trips each corpus bit-perfect
# (t mode, tag defaults, empty environment). Ratios are recorded as declared: the papers
# of these tags publish GPU figures, listed in verify/claims/<tag>.tsv and emitted as
# skipped-no-gpu with their expected values until a CUDA host runs them.
set -uo pipefail
TAG=$1; ROOT=${ROOT:?}; CL="$ROOT/verify/claims/$TAG.tsv"
REC=(); rec(){ REC+=("$(printf '{"claim_id":"%s","level":"%s","expected":"%s","tolerance":"%s","measured":"%s","verdict":"%s","command":"%s"}' "$@")"); }
if make -s >/dev/null 2>&1 && [ -x ./aceapex ]; then rec "${TAG}_build" R builds - built pass "make"
else rec "${TAG}_build" R builds - "make failed" build-failed "make"; fi
for C in genome/chr1.fa text/enwik8 mixed/silesia.tar; do
  N=$(basename "$C" | sed 's/\..*//'); F="$GOLDEN/$C"
  if [ ! -f "$F" ]; then rec "${TAG}_roundtrip_$N" R bit-perfect - "no corpus" skipped-no-corpus "t --in $C"; continue; fi
  [ -x ./aceapex ] || { rec "${TAG}_roundtrip_$N" R bit-perfect - "no binary" build-failed "t --in $C"; continue; }
  O=$(env -i PATH="$PATH" HOME="$HOME" ./aceapex t --in "$F" --threads 8 2>&1)
  R=$(grep -o 'Ratio:  *[0-9.]*' <<<"$O" | grep -o '[0-9.]*$')
  if grep -q 'BIT-PERFECT' <<<"$O"; then rec "${TAG}_roundtrip_$N" R bit-perfect - bit-perfect pass "aceapex t --in $C --threads 8"
  else rec "${TAG}_roundtrip_$N" R bit-perfect - "not bit-perfect" fail "aceapex t --in $C --threads 8"; fi
  rec "${TAG}_ratio_$N" M "-" - "${R:-?}" declared "aceapex t --in $C (tag defaults)"
done
GPU=skipped-no-gpu; command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1 && GPU=declared
[ -f "$CL" ] && while IFS=$'\t' read -r id lvl exp tol needs cmd; do
  case "$id" in ''|\#*) continue;; esac
  V=$GPU; case "$needs" in corpus:*) [ -f "$GOLDEN/${needs#corpus:}" ] && V=declared || V=skipped-no-corpus;;
    tool:*) T=${needs#tool:}; [ -x "${T/#\~/$HOME}" ] && V=declared || V=skipped-no-tool;; esac
  [ "$V" = declared ] && [ "$lvl" = R ] && V=unjudged   # needs met, no runner in this judge yet
  rec "$id" "$lvl" "$exp" "$tol" "-" "$V" "$cmd"; done < "$CL"
{ echo '{"tag":"'"$TAG"'","claims":['; ( IFS=,; echo "${REC[*]}" ); echo ']}'; } > "$RECORDS"
