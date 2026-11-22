#!/usr/bin/env bash
# verify_selftest.sh - the rules of verify.sh checked with throw-away judges (tag HEAD, own JUDGE_DIR / EXPECT_DIR / WT /
# OUT under a temp dir; the repository's results/ and /tmp/aceapex-verify are not touched):
#   A) old records of 5 passing claims exist; the judge writes one passing record and exits 1  -> verify FAILS, no HEAD.json
#   B) the judge writes nothing and exits 0                                                     -> verify FAILS, no HEAD.json
#   C) the judge writes one of the two required claims and exits 0                              -> verify FAILS, no HEAD.json
#   D) control: the judge writes both required claims (pass) and exits 0                        -> verify PASSES, HEAD.json
# Prints one line: verify_selftest <pass|fail> <detail>; exit 0 only when all four behave.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); S=$(mktemp -d /tmp/axvst.XXXXXX)
mkdir -p "$S/j" "$S/e" "$S/wt" "$S/out"; printf 'vst_a\talways\nvst_b\talways\n' > "$S/e/HEAD.tsv"
rec() { printf 'python3 -c "import json,os;json.dump({\\"records\\":[%s]},open(os.environ[\\"RECORDS\\"],\\"w\\"))"\n' "$1"; }
one='{\"claim_id\":\"vst_a\",\"verdict\":\"pass\"}'; two="$one,"'{\"claim_id\":\"vst_b\",\"verdict\":\"pass\"}'
stale='{"records":['; for i in 1 2 3 4 5; do stale+="{\"claim_id\":\"old_$i\",\"verdict\":\"pass\"},"; done; stale="${stale%,}]}"
run() {  # run <case> <judge body> <want rc 0|1> [stale]
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$S/j/HEAD.sh"; rm -f "$S/out/HEAD.json" "$S/out/HEAD.failed.json"
  [ -n "${4:-}" ] && echo "$stale" > "$S/wt/HEAD_records.json"
  ( cd "$ROOT" && JUDGE_DIR="$S/j" EXPECT_DIR="$S/e" WT="$S/wt" OUT="$S/out" ./verify.sh HEAD ) > "$S/$1.log" 2>&1; local rc=$?
  local pub=$([ -f "$S/out/HEAD.json" ] && echo 1 || echo 0)
  if { [ "$3" = 0 ] && [ $rc = 0 ] && [ $pub = 1 ]; } || { [ "$3" = 1 ] && [ $rc != 0 ] && [ $pub = 0 ]; }; then echo "$1:ok"; else echo "$1:BAD(rc=$rc,json=$pub)"; fi; }
r="$(run A "$(rec "$one"); exit 1" 1 stale) $(run B "exit 0" 1) $(run C "$(rec "$one")" 1) $(run D "$(rec "$two")" 0)"
case "$r" in *BAD*) v=fail;; *) v=pass;; esac
printf 'verify_selftest\t%s\tA stale records + 1 record + exit 1, B no records, C a required claim missing -> FAIL and no HEAD.json; D control -> PASS: %s\n' "$v" "$r"
rm -rf "$S"; [ $v = pass ]
