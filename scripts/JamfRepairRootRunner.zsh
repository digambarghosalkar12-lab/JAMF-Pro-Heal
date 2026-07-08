#!/bin/zsh
# JamfRepairRootRunner.zsh
# Runs as root via LaunchDaemon WatchPaths when user approves repair.

set -u

ORG_ID="bd"
STATE_DIR="/var/db/com.${ORG_ID}.jamfrepair"
LOG_FILE="/var/log/com.${ORG_ID}.jamfrepair.runner.log"
APPROVAL_FLAG="$STATE_DIR/run_repair_approved.flag"
RUN_LOCK="$STATE_DIR/repair_running.lock"
REPAIR_SCRIPT="/Library/Application Support/BD/JamfRepair/JamfHealthRepair.zsh"
LOCK_MAX_AGE_SECONDS=$((2 * 60 * 60))

touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE"; }
now_epoch() { date +%s; }

log "========== Starting root runner =========="

if [[ ! -f "$APPROVAL_FLAG" ]]; then
  log "No approval flag. Exiting."
  exit 0
fi

if [[ -f "$RUN_LOCK" ]]; then
  LOCK_AGE=$(( $(now_epoch) - $(stat -f %m "$RUN_LOCK" 2>/dev/null || echo 0) ))
  if [[ "$LOCK_AGE" -lt "$LOCK_MAX_AGE_SECONDS" ]]; then
    log "Repair already running or lock is recent. Exiting."
    exit 0
  fi
  log "Removing stale lock."
  rm -f "$RUN_LOCK"
fi

touch "$RUN_LOCK"
trap 'rm -f "$RUN_LOCK"' EXIT
rm -f "$APPROVAL_FLAG"

if [[ ! -x "$REPAIR_SCRIPT" ]]; then
  log "Repair script missing or not executable: $REPAIR_SCRIPT"
  exit 1
fi

log "Running full repair script: $REPAIR_SCRIPT"
"$REPAIR_SCRIPT" >> "$LOG_FILE" 2>&1
EXIT_CODE="$?"
log "Repair script completed. Exit code=$EXIT_CODE"
exit "$EXIT_CODE"
