#!/bin/bash
# TRAIN-1 on a self-deleting GCP L4 GPU VM (run by the ACEAPEX agent/operator on ace-core,
# gcloud logged in as yasha1971@gmail.com, project aceapex-bench). Same scheme as DUEL/MT-3:
# the ORCHESTRATOR (this script, user creds) creates the VM, scp's cohort/reference/panvram
# source + driver to it, runs the driver, polls STATUS, scp's results back, and DELETES the VM
# in a signal-safe trap. The VM's default service account has NO roles, so the VM never touches
# GCS and never self-deletes; --max-run-duration + DELETE is only the platform backstop.
# panvram is FROZEN: we build from a pinned source archive (git archive 01f0ce1), code UNCHANGED.
#
# Survive a dropped phone / SSH: run THIS script inside server-side tmux on ace-core:
#   tmux new -d -s train1 'bash <path>/train1_gcloud.sh run ~/train1_work 2>&1 | tee ~/train1_work/run.log'
#   stage   (optional) build+upload the 3 tarballs to the GCS bucket (already present; source of truth)
#   run     create VM, provision, run train_small.py, fetch results to <out>, delete VM, copy logs to yasha-context
#
# IMPORTANT: this script does NOT create a VM unless called with `run`. The safety interlock
# forbids the agent from creating VMs; the operator runs the tmux line below.
set -euo pipefail
CMD="${1:?stage|run}"; OUT="${2:?local_out_dir}"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE="$(cd "$(dirname "$0")" && pwd)"
G=~/google-cloud-sdk/bin/gcloud
GS=~/google-cloud-sdk/bin/gsutil
PROJECT=aceapex-bench
BUCKET="${BUCKET:-gs://aceapex-bench-duel1}"      # reuse DUEL bucket: cohort_q4k.tgz + t2t.fa.gz already there
PANVRAM_DIR="${PANVRAM_DIR:-$HOME/panvram}"
PANVRAM_SHA="${PANVRAM_SHA:-01f0ce11ddfbe3bf42ea5c00cb2a644382e0b94d}"  # prereg-pinned HEAD 01f0ce1
COHORT_DIR="${COHORT_DIR:-$HOME/panvram/.data/cohort558}"
REF_FA="${REF_FA:-$HOME/golden/genome/t2t.fa}"
YC_LOGS="${YC_LOGS:-$HOME/yasha-context/ACEAPEX/train1/logs}"
MAXRUN="${MAXRUN:-4h}"                            # with slack; L4 + 3 seeds x 2 models + build
# L4 (G2) machine types and zones to try in order. Quota: NVIDIA_L4_GPUS=1 per region,
# GPUS_ALL_REGIONS=1 (one L4 globally at a time). g2-standard-16 first (64 GB RAM: the
# reference FASTA is tokenised in CPU RAM), then g2-standard-8 (32 GB).
MTS="${MTS:-g2-standard-16 g2-standard-8}"
ZONES="${ZONES:-europe-west4-a europe-west4-b europe-west4-c us-central1-a us-central1-b us-central1-c us-west1-a us-west1-b us-west4-a europe-west1-b europe-west1-c asia-southeast1-a asia-southeast1-b asia-southeast1-c}"
IMG_FAMILY="${IMG_FAMILY:-common-cu123}"
IMG_PROJECT="${IMG_PROJECT:-deeplearning-platform-release}"
STAGE="$OUT/stage"; mkdir -p "$STAGE"
log(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$OUT/gcloud.log"; }

build_tarballs(){
  # panvram_src.tgz is ALWAYS rebuilt from the pinned SHA (tiny, ~5 MB) so we never depend on a
  # stale bucket copy. cohort_q4k.tgz / t2t.fa.gz are large & read-only -> pull from the bucket if
  # present, else build locally (deref the cohort symlinks).
  log "build panvram_src.tgz from $PANVRAM_SHA (pinned)"
  ( cd "$PANVRAM_DIR" && git cat-file -e "${PANVRAM_SHA}^{commit}" ) 2>/dev/null || { log "STOP: $PANVRAM_SHA not in $PANVRAM_DIR"; exit 2; }
  ( cd "$PANVRAM_DIR" && git archive --format=tar "$PANVRAM_SHA" ) > "$STAGE/panvram_src.tar"
  # record the SHA inside the archive so the VM can print it in STATUS/results
  tmpd=$(mktemp -d); printf '%s\n' "$PANVRAM_SHA" > "$tmpd/.panvram_sha"
  tar --append -f "$STAGE/panvram_src.tar" -C "$tmpd" .panvram_sha; rm -rf "$tmpd"
  gzip -f "$STAGE/panvram_src.tar"; mv "$STAGE/panvram_src.tar.gz" "$STAGE/panvram_src.tgz"
  # NB: capture the listing first and match a here-string. `tar tzf ... | grep -q` is wrong under
  # `set -o pipefail`: grep -q closes the pipe on first hit, tar dies with SIGPIPE, and the pipeline
  # reports non-zero even though the file IS present -> false "not in archive" STOP (the original bug).
  if [ ! -f "$STAGE/src_examples_ok" ]; then
    arclist=$(tar tzf "$STAGE/panvram_src.tgz")
    grep -qx 'examples/train_small.py' <<<"$arclist" \
      && touch "$STAGE/src_examples_ok" \
      || { log "STOP: train_small.py not in archive of $PANVRAM_SHA"; exit 2; }
  fi
  for f in cohort_q4k.tgz t2t.fa.gz; do
    [ -s "$STAGE/$f" ] && { log "have $STAGE/$f"; continue; }
    if "$GS" -q stat "$BUCKET/$f" >/dev/null 2>&1; then log "pull $f from bucket (user creds)"; "$GS" -q cp "$BUCKET/$f" "$STAGE/$f"; continue; fi
    case "$f" in
      cohort_q4k.tgz) log "build cohort_q4k.tgz (deref symlinks)"; tar czhf "$STAGE/$f" -C "$COHORT_DIR" $(cd "$COHORT_DIR" && ls *.q4k.rr3);;
      t2t.fa.gz)      log "build t2t.fa.gz from $REF_FA"; gzip -c "$REF_FA" > "$STAGE/$f";;
    esac
  done
}

stage(){
  "$GS" ls -b "$BUCKET" >/dev/null 2>&1 || { log "STOP: bucket $BUCKET not reachable"; exit 2; }
  build_tarballs
  for f in cohort_q4k.tgz t2t.fa.gz; do
    "$GS" -q stat "$BUCKET/$f" >/dev/null 2>&1 || { log "upload $f"; "$GS" -q cp "$STAGE/$f" "$BUCKET/$f"; }
  done
  log "stage done:"; "$GS" ls -l "$BUCKET"/ 2>&1 | tee -a "$OUT/gcloud.log"
}

run(){
  build_tarballs
  for f in panvram_src.tgz cohort_q4k.tgz t2t.fa.gz; do [ -s "$STAGE/$f" ] || { log "STOP: $STAGE/$f missing"; exit 2; }; done
  # GLOBAL (not local): the EXIT trap fires at global scope after run() returns; with set -u,
  # local vars would be gone and cleanup would abort before deleting the VM.
  NAME="train1-$(date -u +%Y%m%d-%H%M%S)"; created=0; ZONE=""; MT=""; CLEANED=0
  GQ(){ "$G" --quiet --project "$PROJECT" "$@"; }
  cleanup(){
    [ "$CLEANED" = 1 ] && return; CLEANED=1
    trap - EXIT INT TERM HUP
    local rc="${1:-0}"
    if [ -n "${NAME:-}" ] && [ -n "${ZONE:-}" ]; then
      log "deleting $NAME ($ZONE) [idempotent, user creds]"
      GQ compute instances delete "$NAME" --zone "$ZONE" --delete-disks=all 2>&1 | tail -3 | tee -a "$OUT/gcloud.log" || true
    fi
    log "instances:"; GQ compute instances list 2>&1 | tee -a "$OUT/gcloud.log" || true
    log "disks:";     GQ compute disks list 2>&1 | tee -a "$OUT/gcloud.log" || true
    exit "$rc"
  }
  trap 'cleanup 0'   EXIT
  trap 'cleanup 130' INT
  trap 'cleanup 143' TERM
  trap 'cleanup 129' HUP

  for MT in $MTS; do
    for ZONE in $ZONES; do
      log "create $NAME $MT in $ZONE (L4, DL $IMG_FAMILY, max $MAXRUN DELETE, TERMINATE maint)"
      if GQ compute instances create "$NAME" --zone "$ZONE" --machine-type "$MT" \
           --image-family "$IMG_FAMILY" --image-project "$IMG_PROJECT" \
           --maintenance-policy TERMINATE --metadata=install-nvidia-driver=True \
           --boot-disk-size 200GB --boot-disk-type pd-balanced \
           --max-run-duration "$MAXRUN" --instance-termination-action DELETE >>"$OUT/gcloud.log" 2>&1; then
        created=1; break; fi
      log "  create in $ZONE failed: $(grep -oE 'Quota [^.]*\.|ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|No available zones' "$OUT/gcloud.log" | tail -1)"
    done; [ "$created" = 1 ] && break
  done
  [ "$created" = 1 ] || { log "STOP: no L4 (g2) VM creatable in any listed zone (quota/capacity)"; exit 3; }
  local T0; T0=$(date +%s); log "created $NAME ($MT, $ZONE)"
  SSH(){ GQ compute ssh "$NAME" --zone "$ZONE" --command "$1"; }
  SCP(){ GQ compute scp --zone "$ZONE" "$@"; }
  local i; for i in $(seq 1 60); do SSH true >/dev/null 2>&1 && break; sleep 15; done
  SSH 'nvidia-smi -L 2>/dev/null || echo "nvidia-smi not ready yet (driver installing)"; nproc; free -g | head -2; df -h / | tail -1' | tee -a "$OUT/gcloud.log" || { log "STOP: SSH never came up"; exit 4; }
  log "scp cohort/ref/panvram-src (~12.5 GB) + driver to VM"
  SCP "$STAGE/panvram_src.tgz" "$STAGE/cohort_q4k.tgz" "$STAGE/t2t.fa.gz" "$NAME":~/ >>"$OUT/gcloud.log" 2>&1
  SCP "$HERE/train1_driver.sh" "$NAME":~/ >>"$OUT/gcloud.log" 2>&1
  SSH 'nohup bash ~/train1_driver.sh ~/train1_out > ~/train1.nohup 2>&1 < /dev/null &'
  log "driver started; polling STATUS (this orchestrator lives in server-side tmux)"
  local last="" LIMIT=$(( ${MAXRUN%h} * 3600 - 1200 ))   # stop polling 20 min before the backstop
  while :; do
    sleep 120
    st=$(SSH 'tail -1 ~/train1_out/STATUS 2>/dev/null' 2>/dev/null || true)
    [ "$st" != "$last" ] && log "  $st"; last="$st"
    case "$st" in *"ALL DONE"*|*"DIE:"*) break;; esac
    [ $(( $(date +%s) - T0 )) -gt "$LIMIT" ] && { log "STOP: poll limit before VM max-run-duration"; break; }
  done
  log "fetch results -> $OUT"
  SSH 'cd ~ && tar czf train1_out.tgz train1_out/logs train1_out/results train1_out/STATUS train1.nohup' >>"$OUT/gcloud.log" 2>&1 || true
  SCP "$NAME":~/train1_out.tgz "$OUT/" >>"$OUT/gcloud.log" 2>&1 || log "WARN results fetch failed"
  ( cd "$OUT" && tar xzf train1_out.tgz ) >>"$OUT/gcloud.log" 2>&1 || true
  # copy the logs + summary into yasha-context (prereg requires the log there)
  mkdir -p "$YC_LOGS" 2>/dev/null || true
  cp -f "$OUT"/train1_out/logs/*.log "$OUT"/train1_out/results/train1_summary.json \
        "$OUT"/train1_out/results/train1_runs.jsonl "$OUT"/train1_out/STATUS "$YC_LOGS"/ 2>/dev/null || log "WARN: copy to $YC_LOGS partial"
  log "VM wall $(( ($(date +%s) - T0)/60 )) min, $MT, $ZONE"
  log "results in $OUT/train1_out/results ; logs copied to $YC_LOGS"
  if [ -s "$OUT/train1_out/results/train1_summary.json" ]; then log "SUMMARY:"; cat "$OUT/train1_out/results/train1_summary.json" | tee -a "$OUT/gcloud.log"; fi
  # cleanup trap now deletes the VM and prints empty instance/disk lists
}

case "$CMD" in stage) stage;; run) run;; *) echo "stage|run"; exit 2;; esac
