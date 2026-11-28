#!/usr/bin/env bash
# Claim head_run_template_pg (RT-PG-1, 28.11.2026): the watchdog of scripts/run_template.sh ends the command's whole process
# group. A scratch CALIBRATION with a committed line, WATCHDOG=2, the command `bash -c 'sleep M & sleep M'` (a child with a
# grandchild; M a marker duration unique to this run); 5 s after the watchdog no process with the marker may be alive.
# Negative control RT_NO_PGROUP=1 (the template before RT-PG-1, which signalled the child only): the grandchild survives.
# Leftovers are killed at the end. Prints one judge line: head_run_template_pg <pass|fail> <detail>.
set -uo pipefail
RT="$(cd "$(dirname "$0")" && pwd)/run_template.sh"; T=$(mktemp -d)
M="31$((RANDOM % 900 + 100)).$$"; trap 'pkill -f "sleep $M" 2>/dev/null; rm -rf "$T"' EXIT
git -C "$T" init -q && git -C "$T" config user.email t@t && git -C "$T" config user.name t
echo '| 2026-11-28 | PG-1 (записан до прогона) | прогноз X, вероятность 60 %; убийственный критерий: Y; правило подсчёта: Z. Опора: A. Потолок: B | | |' > "$T/CALIBRATION.md"
git -C "$T" add CALIBRATION.md && git -C "$T" commit -q -m c
run() { CALIB="$T/CALIBRATION.md" RUN_DIR="$T/run_$1" WATCHDOG=2 RT_NO_PGROUP=$2 bash "$RT" PG-1 -- bash -c "sleep $M & sleep $M" >/dev/null 2>&1; local rc=$?
  sleep 5; local alive; alive=$(pgrep -fc "sleep $M" || true); pkill -f "sleep $M" 2>/dev/null; sleep 1; echo "$rc $alive"; }
read -r rn an < <(run new 0); read -r ro ao < <(run old 1)
grep -q 'terminating process group' "$T/run_new/STATUS" && wn=yes || wn=no
pass=fail; [ "$an" = 0 ] && [ "$ao" -ge 1 ] && [ "$rn" = 2 ] && [ "$wn" = yes ] && pass=pass
printf 'head_run_template_pg\t%s\tnew: rc %s, %s marker processes alive 5 s after the watchdog, group line %s | control RT_NO_PGROUP=1: rc %s, %s alive (the grandchild)\n' "$pass" "$rn" "$an" "$wn" "$ro" "$ao"
[ "$pass" = pass ]
