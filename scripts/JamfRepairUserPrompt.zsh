#!/bin/zsh
# JamfRepairUserPrompt.zsh
# Runs as logged-in user via LaunchAgent. Shows native notification first; after 2 days uses SwiftDialog.

set -u

ORG_ID="bd"
STATE_DIR="/var/db/com.${ORG_ID}.jamfrepair"
LOG_FILE="/tmp/com.${ORG_ID}.jamfrepair.userprompt.log"
DIALOG="/usr/local/bin/dialog"

ISSUE_TYPE_FILE="$STATE_DIR/issue_type"
ISSUE_REASON_FILE="$STATE_DIR/issue_reason"
ISSUE_FIRST_EPOCH_FILE="$STATE_DIR/issue_first_detected_epoch"
ISSUE_REPAIR_ALLOWED_FILE="$STATE_DIR/issue_repair_allowed"
LAST_NOTIFY_EPOCH_FILE="$STATE_DIR/last_user_notification_epoch"
LAST_DIALOG_EPOCH_FILE="$STATE_DIR/last_swiftdialog_epoch"
APPROVAL_FLAG="$STATE_DIR/run_repair_approved.flag"
PROMPT_LOCK="$STATE_DIR/user_prompt.lock"

# First 2 days = notification only. After 2 days = SwiftDialog button prompt.
SWIFTDIALOG_AFTER_SECONDS=$((2 * 24 * 60 * 60))
NOTIFICATION_THROTTLE_SECONDS=$((6 * 60 * 60))
DIALOG_THROTTLE_SECONDS=$((4 * 60 * 60))
LOCK_MAX_AGE_SECONDS=900

touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE"; }
now_epoch() { date +%s; }
read_file() { [[ -f "$1" ]] && cat "$1" 2>/dev/null || true; }

log "========== Starting user prompt check =========="

if [[ ! -f "$ISSUE_TYPE_FILE" ]]; then
  log "No issue found. Exiting."
  exit 0
fi

# Avoid overlapping prompts.
if [[ -f "$PROMPT_LOCK" ]]; then
  LOCK_AGE=$(( $(now_epoch) - $(stat -f %m "$PROMPT_LOCK" 2>/dev/null || echo 0) ))
  if [[ "$LOCK_AGE" -lt "$LOCK_MAX_AGE_SECONDS" ]]; then
    log "Prompt lock exists and is recent. Exiting."
    exit 0
  fi
fi

touch "$PROMPT_LOCK"
trap 'rm -f "$PROMPT_LOCK"' EXIT

ISSUE_TYPE="$(read_file "$ISSUE_TYPE_FILE")"
ISSUE_REASON="$(read_file "$ISSUE_REASON_FILE")"
FIRST_EPOCH="$(read_file "$ISSUE_FIRST_EPOCH_FILE")"
REPAIR_ALLOWED="$(read_file "$ISSUE_REPAIR_ALLOWED_FILE")"
NOW="$(now_epoch)"

[[ -z "$FIRST_EPOCH" ]] && FIRST_EPOCH="$NOW"
AGE_SECONDS=$(( NOW - FIRST_EPOCH ))
AGE_HOURS=$(( AGE_SECONDS / 3600 ))

show_native_notification() {
  local title="$1"
  local msg="$2"
  /usr/bin/osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1
}

should_throttle_file() {
  local file="$1"
  local throttle="$2"
  local last="$(read_file "$file")"
  [[ -z "$last" ]] && return 1
  [[ $(( NOW - last )) -lt "$throttle" ]]
}

TITLE="Jamf / MDM Status"
MESSAGE="Issue detected: $ISSUE_TYPE

$ISSUE_REASON

Detected for approximately ${AGE_HOURS} hour(s)."

if [[ "$REPAIR_ALLOWED" != "true" ]]; then
  # Network/Jamf connectivity/speed issue: never run repair.
  if ! should_throttle_file "$LAST_NOTIFY_EPOCH_FILE" "$NOTIFICATION_THROTTLE_SECONDS"; then
    show_native_notification "$TITLE" "$ISSUE_TYPE: $ISSUE_REASON"
    echo "$NOW" > "$LAST_NOTIFY_EPOCH_FILE"
    chmod 644 "$LAST_NOTIFY_EPOCH_FILE"
    log "Native notification shown for non-repair issue: $ISSUE_TYPE"
  else
    log "Notification throttled for non-repair issue."
  fi
  exit 0
fi

# Repairable issue but less than 2 days old: notification only.
if [[ "$AGE_SECONDS" -lt "$SWIFTDIALOG_AFTER_SECONDS" ]]; then
  if ! should_throttle_file "$LAST_NOTIFY_EPOCH_FILE" "$NOTIFICATION_THROTTLE_SECONDS"; then
    show_native_notification "Jamf Repair Available" "Jamf/MDM issue detected. If this remains for 2 days, a repair prompt will appear."
    echo "$NOW" > "$LAST_NOTIFY_EPOCH_FILE"
    chmod 644 "$LAST_NOTIFY_EPOCH_FILE"
    log "Native notification shown for repairable issue. Age=${AGE_SECONDS}s"
  else
    log "Notification throttled for repairable issue. Age=${AGE_SECONDS}s"
  fi
  exit 0
fi

# After 2 days: show SwiftDialog prompt with Run Repair button.
if should_throttle_file "$LAST_DIALOG_EPOCH_FILE" "$DIALOG_THROTTLE_SECONDS"; then
  log "SwiftDialog prompt throttled."
  exit 0
fi

DIALOG_MESSAGE="Your Mac has detected a Jamf / MDM management issue for more than 2 days.

Issue:
$ISSUE_TYPE

Details:
$ISSUE_REASON

This does not look like a temporary Wi-Fi issue because the hourly checker already separates bad internet, slow internet, and Jamf connectivity issues.

Click Run Repair Now to start Jamf / MDM repair."

EXIT_CODE=1
if [[ -x "$DIALOG" ]]; then
  "$DIALOG" \
    --title "Jamf / MDM Repair Required" \
    --message "$DIALOG_MESSAGE" \
    --icon "SF=exclamationmark.triangle.fill" \
    --button1text "Run Repair Now" \
    --button2text "Later" \
    --ontop \
    --moveable \
    --width 820 \
    --height 620
  EXIT_CODE="$?"
else
  /usr/bin/osascript -e "display dialog \"$DIALOG_MESSAGE\" with title \"Jamf / MDM Repair Required\" buttons {\"Later\", \"Run Repair Now\"} default button \"Run Repair Now\""
  EXIT_CODE="$?"
fi

echo "$NOW" > "$LAST_DIALOG_EPOCH_FILE"
chmod 644 "$LAST_DIALOG_EPOCH_FILE"

# swiftDialog Button 1 returns 0. AppleScript default button also returns 0.
if [[ "$EXIT_CODE" -eq 0 ]]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - User approved repair" > "$APPROVAL_FLAG"
  chmod 644 "$APPROVAL_FLAG"
  log "User approved repair. Approval flag created."
else
  log "User did not approve repair. Exit code=$EXIT_CODE"
fi

exit 0
