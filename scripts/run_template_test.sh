#!/usr/bin/env bash
# Claim head_run_template_gate (GUARD-1, 23.11.2026): scripts/run_template.sh starts a run only when CALIBRATION holds a
# COMMITTED line for the task with the prediction fields (опора, потолок, вероятность), the killer criterion and the
# counting rule. A scratch git repository with seven CALIBRATION variants, the dry gate check (no command) on each:
#   full + committed -> exit 0 (and the run itself starts: `-- true` -> exit 0);
#   full but only in the working tree, each field missing (5 cases) -> STOP, exit 2 (every gate can fail).
# Prints one judge line: head_run_template_gate <pass|fail> <detail>.
set -uo pipefail
RT="$(cd "$(dirname "$0")" && pwd)/run_template.sh"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git -C "$T" init -q && git -C "$T" config user.email t@t && git -C "$T" config user.name t
FULL='| 2026-11-23 | GT-1 (записан до прогона) | прогноз X, вероятность 60 %; убийственный критерий: Y; правило подсчёта: Z. Опора: A. Потолок: B | | |'
case_run() {   # name, line, commit(0/1), expected exit, [command]
  local name=$1 line=$2 commit=$3 want=$4; shift 4
  printf '| дата | задание | прогноз | факт | попадание |\n|---|---|---|---|---|\n' > "$T/CALIBRATION.md"
  git -C "$T" add CALIBRATION.md && git -C "$T" commit -qm base --allow-empty >/dev/null
  printf '%s\n' "$line" >> "$T/CALIBRATION.md"; [ "$commit" = 1 ] && git -C "$T" commit -qam "$name" >/dev/null
  CALIB="$T/CALIBRATION.md" RUN_DIR="$T/run_$name" bash "$RT" GT-1 "$@" > "$T/$name.out" 2>&1; local rc=$?
  git -C "$T" checkout -q -- CALIBRATION.md 2>/dev/null
  printf '%s=%s ' "$name" "$rc"; [ "$rc" = "$want" ]
}
ok=0; n=0; det=""
for spec in "full_committed|$FULL|1|0" "full_uncommitted|$FULL|0|2" \
            "no_kill|${FULL/убийственный критерий: Y; /}|1|2" "no_rule|${FULL/правило подсчёта: Z. /}|1|2" \
            "no_basis|${FULL/Опора: A. /}|1|2" "no_ceiling|${FULL/ Потолок: B/}|1|2" "no_probability|${FULL/вероятность 60 %; /}|1|2"; do
  IFS='|' read -r name rest <<<"$spec"; line="${spec#*|}"; line="${line%|*|*}"; commit="${spec%|*}"; commit="${commit##*|}"; want="${spec##*|}"
  n=$((n+1)); r=$(case_run "$name" "$line" "$commit" "$want") && ok=$((ok+1)); det="$det$r"
done
n=$((n+1)); r=$(case_run run_starts "$FULL" 1 0 -- true) && ok=$((ok+1)); det="$det$r"
grep -q "committed in" "$T/full_committed.out" && grep -q "убийственный критерий" "$T/no_kill.out" && grep -q "not committed" "$T/full_uncommitted.out" || { ok=0; det="$det (STATUS messages missing)"; }
[ $ok -eq $n ] && v=pass || v=fail
printf 'head_run_template_gate\t%s\t%d/%d cases as expected (exit codes: %s) - a run starts only with a committed line carrying опора, потолок, вероятность, the killer criterion and the counting rule\n' "$v" $ok $n "$det"
[ $v = pass ]
