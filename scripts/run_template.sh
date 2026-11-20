#!/usr/bin/env bash
# Template for every long run (CLAUDE.md §2): STATUS log, hang watchdog, PID wait,
# explicit STOP, `trap ERR`. Do not rewrite per task — source or copy this.
#
# GATE (CLAUDE.md §0.4): the run refuses to start unless CALIBRATION has a prediction
# line for THIS task carrying all three fields — «опора», «потолок», «вероятность»
# (or an explicit %). Negative control: a line missing any field makes the gate STOP
# (every gate must be able to fail).
#
# Usage: run_template.sh <task-name-as-in-CALIBRATION> [-- <command...>]
#   CALIB=<file>    override CALIBRATION path (default ~/yasha-context/ACEAPEX/CALIBRATION.md)
#   WATCHDOG=3600   hang watchdog seconds (default 3600 = 60 min)
#   RUN_DIR=<dir>   the run's folder (default ${TMPDIR:-/tmp}/run_template/<task>); created if missing
#   STATUS=<file>   STATUS log path (default $RUN_DIR/STATUS - never the current directory: a dry gate check run
#                   from a repository root left an untracked STATUS there, 20.11)
# No command after the task name = dry gate check (exit 0 if the gate passes, 2 if it STOPs).
set -euo pipefail
TASK="${1:?task name as written in CALIBRATION}"; shift || true
[ "${1:-}" = "--" ] && shift || true
CALIB="${CALIB:-$HOME/yasha-context/ACEAPEX/CALIBRATION.md}"
WATCHDOG="${WATCHDOG:-3600}"
RUN_DIR="${RUN_DIR:-${TMPDIR:-/tmp}/run_template/$(printf '%s' "$TASK" | tr -c 'A-Za-z0-9._-' '_')}"
mkdir -p "$RUN_DIR"
STATUS="${STATUS:-$RUN_DIR/STATUS}"
log(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$STATUS"; }
die(){ log "STOP: $*"; exit 2; }
trap 'die "trap ERR (line $LINENO)"' ERR

# --- §0.4 environment gate: prediction line present with the required fields ---
calibration_gate(){
  local task="$1" line; local -a missing=()
  [ -r "$CALIB" ] || die "CALIBRATION not readable: $CALIB"
  line=$(grep -E '^\|' "$CALIB" | grep -F "| $task " | head -1 || true)
  [ -n "$line" ] || die "no CALIBRATION line for task '$task' — prediction must be written BEFORE the run (§0.4)"
  grep -qi 'опора'                  <<<"$line" || missing+=("опора")
  grep -qi 'потолок'                <<<"$line" || missing+=("потолок")
  grep -qiE 'вероятность|уверенность|[0-9]+ ?%'  <<<"$line" || missing+=("вероятность")
  [ "${#missing[@]}" -eq 0 ] || die "CALIBRATION line for '$task' missing field(s): ${missing[*]} (§0.4 requires опора/потолок/вероятность)"
  log "CALIBRATION gate OK for '$task' — опора/потолок/вероятность present"
}
calibration_gate "$TASK"

# --- silesia reference gate: if SILESIA is set, it MUST be the reference corpus ---
# sha256 a667bac8…, 211 947 520 B (/tmp/hwref/corpus/silesia.tar). Guards against the
# golden/mixed variant (211 957 760, sha 3eee8566) and the 38-byte ~/CORPORA stub (§1).
SILESIA="${SILESIA:-}"
silesia_gate(){
  [ -n "$SILESIA" ] || return 0
  [ -r "$SILESIA" ] || die "SILESIA not readable: $SILESIA"
  local s; s=$(sha256sum "$SILESIA" | cut -c1-8)
  [ "$s" = "a667bac8" ] || die "silesia '$SILESIA' sha $s != reference a667bac8 (use /tmp/hwref/corpus/silesia.tar, 211 947 520 B; §1)"
  log "silesia reference OK ($SILESIA sha a667bac8)"
}
silesia_gate

[ "$#" -gt 0 ] || { log "env gate passed; no command (dry gate check) — done"; exit 0; }

# --- hang watchdog + PID wait + explicit STOP ---
log "START '$TASK': $*"
"$@" & CHILD=$!
# the watchdog's sleep is killed with it and it writes only to STATUS: until 20.11 its sleep outlived `kill $WD` for up to
# WATCHDOG seconds and held stdout, so `run_template.sh ... | tail` waited for the whole watchdog time
( exec >/dev/null 2>&1; trap 'kill "$S" 2>/dev/null; exit 0' TERM; sleep "$WATCHDOG" & S=$!; wait "$S" || true
  if kill -0 "$CHILD" 2>/dev/null; then echo "[$(date -u +%FT%TZ)] [watchdog] ${WATCHDOG}s elapsed, terminating $CHILD" >> "$STATUS"; kill -TERM "$CHILD" 2>/dev/null || true; fi ) & WD=$!
rc=0; wait "$CHILD" || rc=$?
kill "$WD" 2>/dev/null || true
[ "$rc" -eq 0 ] && log "DONE '$TASK' rc=0" || die "'$TASK' exited rc=$rc"
