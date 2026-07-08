#!/bin/zsh
####################################################################################################
# Install-JamfSelfHeal.sh
# Single Jamf Pro policy installer for Jamf Self-Heal LaunchDaemon/LaunchAgent workflow.
#
# Jamf Parameters:
#   Parameter 4: Expected Jamf URL, e.g. https://yourcompany.jamfcloud.com
#   Parameter 5: Org ID / prefix, default bd
#   Parameter 6: SwiftDialog path, default /usr/local/bin/dialog
#   Parameter 7: Mode: install or uninstall, default install
#
# Install command in Jamf:
#   Run this script from a Jamf policy. Jamf runs scripts as root.
####################################################################################################

set -u

JAMF_URL_PARAM="${4:-}"
ORG_ID_PARAM="${5:-bd}"
DIALOG_PATH_PARAM="${6:-/usr/local/bin/dialog}"
MODE_PARAM="${7:-install}"

BASE_DIR="/Library/Application Support/BD/JamfRepair"
STATE_DIR="/var/db/com.bd.jamfrepair"
LOG_FILE="/var/log/com.bd.jamfrepair.installer.log"

HEALTHCHECK_DAEMON="/Library/LaunchDaemons/com.bd.jamf.healthcheck.plist"
REPAIR_RUNNER_DAEMON="/Library/LaunchDaemons/com.bd.jamf.repair.runner.plist"
USER_PROMPT_AGENT="/Library/LaunchAgents/com.bd.jamf.repair.prompt.plist"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This installer must run as root."
  exit 1
fi

console_user() {
  stat -f%Su /dev/console 2>/dev/null || true
}

console_uid() {
  local u="$1"
  id -u "$u" 2>/dev/null || true
}

unload_all() {
  log "Unloading existing launchd jobs if present."
  /bin/launchctl bootout system "$HEALTHCHECK_DAEMON" >/dev/null 2>&1 || true
  /bin/launchctl bootout system "$REPAIR_RUNNER_DAEMON" >/dev/null 2>&1 || true

  local u uid
  u="$(console_user)"
  uid="$(console_uid "$u")"
  if [[ -n "$uid" && "$u" != "root" && "$u" != "loginwindow" && "$u" != "_mbsetupuser" ]]; then
    /bin/launchctl bootout "gui/$uid" "$USER_PROMPT_AGENT" >/dev/null 2>&1 || true
  fi
}

load_all() {
  log "Loading LaunchDaemons."
  /bin/launchctl bootstrap system "$HEALTHCHECK_DAEMON" || true
  /bin/launchctl enable system/com.bd.jamf.healthcheck || true

  /bin/launchctl bootstrap system "$REPAIR_RUNNER_DAEMON" || true
  /bin/launchctl enable system/com.bd.jamf.repair.runner || true

  local u uid
  u="$(console_user)"
  uid="$(console_uid "$u")"
  if [[ -n "$uid" && "$u" != "root" && "$u" != "loginwindow" && "$u" != "_mbsetupuser" ]]; then
    log "Loading LaunchAgent for logged-in user: $u ($uid)."
    /bin/launchctl bootstrap "gui/$uid" "$USER_PROMPT_AGENT" || true
    /bin/launchctl enable "gui/$uid/com.bd.jamf.repair.prompt" || true
  else
    log "No valid logged-in user found. LaunchAgent will load after next login or by Jamf restart/check-in workflow."
  fi
}

uninstall_all() {
  log "Starting uninstall."
  unload_all
  rm -f "$HEALTHCHECK_DAEMON" "$REPAIR_RUNNER_DAEMON" "$USER_PROMPT_AGENT"
  rm -rf "$BASE_DIR"
  # Keep state/log by default for audit. Uncomment next line for full wipe.
  # rm -rf "$STATE_DIR"
  log "Uninstall completed."
}

if [[ "$MODE_PARAM" == "uninstall" ]]; then
  uninstall_all
  exit 0
fi

log "========== Installing Jamf Self-Heal workflow =========="
log "Expected Jamf URL parameter: ${JAMF_URL_PARAM:-not set}"
log "Org ID parameter: $ORG_ID_PARAM"
log "Dialog path parameter: $DIALOG_PATH_PARAM"

mkdir -p "$BASE_DIR" "$STATE_DIR" "/Library/LaunchDaemons" "/Library/LaunchAgents"

# Central config file. Scripts source this file after their defaults.
cat > "$BASE_DIR/config.zsh" <<CONFIG_EOF
# Jamf Self-Heal central config
EXPECTED_JAMF_URL="$JAMF_URL_PARAM"
ORG_ID="bd"
DIALOG="$DIALOG_PATH_PARAM"
CONFIG_EOF

cat > "$BASE_DIR/JamfHealthCheckLite.zsh" <<'JAMF_SELF_HEAL_EOF_scripts_JamfHealthCheckLite_zsh'
#!/bin/zsh
# JamfHealthCheckLite.zsh
# Root hourly checker. Classifies issue correctly so bad internet is not treated as Jamf failure.

set -u

CONFIG_FILE="/Library/Application Support/BD/JamfRepair/config.zsh"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"


ORG_ID="bd"
STATE_DIR="/var/db/com.${ORG_ID}.jamfrepair"
LOG_FILE="/var/log/com.${ORG_ID}.jamfrepair.healthcheck.log"

JAMF_BINARY="/usr/local/bin/jamf"
JAMF_PLIST="/Library/Preferences/com.jamfsoftware.jamf.plist"

# EDIT THIS BEFORE PRODUCTION
EXPECTED_JAMF_URL=""
BAD_SPEED_BELOW_MBPS=50

ISSUE_TYPE_FILE="$STATE_DIR/issue_type"
ISSUE_REASON_FILE="$STATE_DIR/issue_reason"
ISSUE_FIRST_EPOCH_FILE="$STATE_DIR/issue_first_detected_epoch"
ISSUE_LAST_EPOCH_FILE="$STATE_DIR/issue_last_detected_epoch"
ISSUE_REPAIR_ALLOWED_FILE="$STATE_DIR/issue_repair_allowed"
LAST_GOOD_FILE="$STATE_DIR/last_good_epoch"
LAST_RESULT_FILE="$STATE_DIR/last_result"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"
chmod 755 "$STATE_DIR"
chmod 644 "$LOG_FILE"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE"; }
now_epoch() { date +%s; }

clear_issue() {
  rm -f "$ISSUE_TYPE_FILE" "$ISSUE_REASON_FILE" "$ISSUE_FIRST_EPOCH_FILE" "$ISSUE_LAST_EPOCH_FILE" "$ISSUE_REPAIR_ALLOWED_FILE"
}

set_issue() {
  local type="$1"
  local reason="$2"
  local repair_allowed="$3" # true/false
  local now="$(now_epoch)"
  local old_type=""

  [[ -f "$ISSUE_TYPE_FILE" ]] && old_type="$(cat "$ISSUE_TYPE_FILE" 2>/dev/null)"

  if [[ "$old_type" != "$type" || ! -f "$ISSUE_FIRST_EPOCH_FILE" ]]; then
    echo "$now" > "$ISSUE_FIRST_EPOCH_FILE"
  fi

  echo "$type" > "$ISSUE_TYPE_FILE"
  echo "$reason" > "$ISSUE_REASON_FILE"
  echo "$now" > "$ISSUE_LAST_EPOCH_FILE"
  echo "$repair_allowed" > "$ISSUE_REPAIR_ALLOWED_FILE"
  echo "$type|$repair_allowed|$reason|$(date '+%Y-%m-%d %H:%M:%S')" > "$LAST_RESULT_FILE"
  chmod 644 "$STATE_DIR"/* 2>/dev/null
  log "ISSUE: [$type] repair_allowed=$repair_allowed reason=$reason"
}

get_host_from_url() { echo "$1" | awk -F/ '{print $3}'; }
test_dns() { /usr/bin/dscacheutil -q host -a name "$1" >/dev/null 2>&1; }
test_https() { /usr/bin/curl -I --silent --show-error --connect-timeout 15 --max-time 30 "$1" >/dev/null 2>>"$LOG_FILE"; }

log "========== Starting classified Jamf health check =========="

# 1. General internet first. Do not confuse network outage with Jamf issue.
if ! test_dns "www.apple.com"; then
  set_issue "NETWORK_ISSUE" "DNS resolution failed for www.apple.com. This is not a Jamf repair issue." "false"
  exit 2
fi

if ! test_https "https://www.apple.com"; then
  set_issue "NETWORK_ISSUE" "HTTPS connection to www.apple.com failed. This is not a Jamf repair issue." "false"
  exit 2
fi
log "General internet check passed."

# 2. Speed check. Slow speed is user/network issue, not Jamf broken.
if command -v networkQuality >/dev/null 2>&1; then
  NQ_OUTPUT="$(networkQuality 2>&1)"
  echo "$NQ_OUTPUT" >> "$LOG_FILE"
  DOWNLINK="$(echo "$NQ_OUTPUT" | awk -F': ' '/Downlink capacity/ {print $2}' | awk '{print $1}' | tail -1)"
  DOWNLINK_INT="$(printf '%.0f' "$DOWNLINK" 2>/dev/null || true)"
  if [[ -n "${DOWNLINK_INT:-}" && "$DOWNLINK_INT" -lt "$BAD_SPEED_BELOW_MBPS" ]]; then
    set_issue "SLOW_INTERNET" "Internet speed is bad: ${DOWNLINK} Mbps. Jamf repair will not run for speed issue only." "false"
    exit 3
  fi
  log "Internet speed acceptable or unparsed: ${DOWNLINK:-unknown} Mbps."
else
  log "networkQuality not available. Speed test skipped."
fi

# 3. Jamf URL connectivity. If general internet works but Jamf URL fails, do not remove Jamf immediately.
DISCOVERED_JAMF_URL=""
if [[ -n "$EXPECTED_JAMF_URL" ]]; then
  DISCOVERED_JAMF_URL="$EXPECTED_JAMF_URL"
elif [[ -f "$JAMF_PLIST" ]]; then
  DISCOVERED_JAMF_URL="$(defaults read "$JAMF_PLIST" jss_url 2>/dev/null || true)"
fi

if [[ -n "$DISCOVERED_JAMF_URL" ]]; then
  JAMF_HOST="$(get_host_from_url "$DISCOVERED_JAMF_URL")"
  if [[ -z "$JAMF_HOST" ]]; then
    set_issue "JAMF_CLIENT_BROKEN" "Jamf URL exists but host could not be parsed: $DISCOVERED_JAMF_URL" "true"
    exit 10
  fi
  if ! test_dns "$JAMF_HOST"; then
    set_issue "JAMF_CONNECTIVITY_ISSUE" "DNS failed for Jamf host $JAMF_HOST. Check VPN/proxy/DNS/Jamf availability before repair." "false"
    exit 5
  fi
  if ! test_https "$DISCOVERED_JAMF_URL"; then
    set_issue "JAMF_CONNECTIVITY_ISSUE" "HTTPS/SSL failed to Jamf URL. Check proxy/SSL/VPN/Jamf availability before repair." "false"
    exit 5
  fi
  log "Jamf URL connectivity passed."
else
  log "No Jamf URL discovered before local checks."
fi

# 4. Local Jamf client checks.
if [[ ! -x "$JAMF_BINARY" ]]; then
  set_issue "JAMF_CLIENT_BROKEN" "Jamf binary is missing or not executable." "true"
  exit 10
fi

if [[ ! -f "$JAMF_PLIST" ]]; then
  set_issue "JAMF_CLIENT_BROKEN" "Jamf plist is missing." "true"
  exit 10
fi

LOCAL_JAMF_URL="$(defaults read "$JAMF_PLIST" jss_url 2>/dev/null || true)"
if [[ -z "$LOCAL_JAMF_URL" ]]; then
  set_issue "JAMF_CLIENT_BROKEN" "Jamf plist exists but jss_url is missing." "true"
  exit 10
fi

if [[ -n "$EXPECTED_JAMF_URL" && "$LOCAL_JAMF_URL" != "$EXPECTED_JAMF_URL" ]]; then
  set_issue "JAMF_CLIENT_BROKEN" "Jamf URL mismatch. Expected $EXPECTED_JAMF_URL but found $LOCAL_JAMF_URL." "true"
  exit 10
fi
log "Local Jamf client checks passed."

# 5. MDM profile check.
ENROLLMENT_STATUS="$(profiles status -type enrollment 2>&1)"
echo "$ENROLLMENT_STATUS" >> "$LOG_FILE"
if ! echo "$ENROLLMENT_STATUS" | grep -qi "MDM enrollment: Yes"; then
  set_issue "MDM_PROFILE_MISSING" "MDM enrollment profile is missing." "true"
  exit 11
fi
log "MDM enrollment profile exists."

# 6. Jamf connection check. Since general internet + Jamf HTTPS passed, this is likely Jamf client/trust/framework issue.
if ! "$JAMF_BINARY" checkJSSConnection >/dev/null 2>&1; then
  set_issue "JAMF_CLIENT_OR_TRUST_ISSUE" "jamf checkJSSConnection failed even though internet and Jamf HTTPS tests passed." "true"
  exit 12
fi
log "jamf checkJSSConnection passed."

clear_issue
echo "$(now_epoch)" > "$LAST_GOOD_FILE"
echo "GOOD|true|Jamf, MDM, internet, and connectivity checks passed.|$(date '+%Y-%m-%d %H:%M:%S')" > "$LAST_RESULT_FILE"
chmod 644 "$STATE_DIR"/* 2>/dev/null
log "Jamf classified health check passed."
exit 0
JAMF_SELF_HEAL_EOF_scripts_JamfHealthCheckLite_zsh

cat > "$BASE_DIR/JamfRepairUserPrompt.zsh" <<'JAMF_SELF_HEAL_EOF_scripts_JamfRepairUserPrompt_zsh'
#!/bin/zsh
# JamfRepairUserPrompt.zsh
# Runs as logged-in user via LaunchAgent. Shows native notification first; after 2 days uses SwiftDialog.

set -u

CONFIG_FILE="/Library/Application Support/BD/JamfRepair/config.zsh"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"


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
JAMF_SELF_HEAL_EOF_scripts_JamfRepairUserPrompt_zsh

cat > "$BASE_DIR/JamfRepairRootRunner.zsh" <<'JAMF_SELF_HEAL_EOF_scripts_JamfRepairRootRunner_zsh'
#!/bin/zsh
# JamfRepairRootRunner.zsh
# Runs as root via LaunchDaemon WatchPaths when user approves repair.

set -u

CONFIG_FILE="/Library/Application Support/BD/JamfRepair/config.zsh"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"


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
JAMF_SELF_HEAL_EOF_scripts_JamfRepairRootRunner_zsh

cat > "$BASE_DIR/JamfHealthRepair.zsh" <<'JAMF_SELF_HEAL_EOF_scripts_JamfHealthRepair_zsh'
#!/bin/zsh
# JamfHealthRepair.zsh
# Full root repair script. Triggered only after user approves via SwiftDialog after 2 days.

set -u

CONFIG_FILE="/Library/Application Support/BD/JamfRepair/config.zsh"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"


ORG_ID="bd"
STATE_DIR="/var/db/com.${ORG_ID}.jamfrepair"
LOG_FILE="/var/log/com.${ORG_ID}.jamfrepair.fullrepair.log"
DIALOG="/usr/local/bin/dialog"
DIALOG_COMMAND_FILE="/var/tmp/com.${ORG_ID}.jamfrepair.reenroll.dialog"

JAMF_BINARY="/usr/local/bin/jamf"
JAMF_PLIST="/Library/Preferences/com.jamfsoftware.jamf.plist"
SELF_SERVICE_APP="/Applications/Self Service.app"

# EDIT THIS BEFORE PRODUCTION
EXPECTED_JAMF_URL=""
BAD_SPEED_BELOW_MBPS=50
REENROLL_GUIDE_SECONDS=180
REENROLL_VALIDATION_ATTEMPTS=24
REENROLL_VALIDATION_SLEEP_SECONDS=15

DISCOVERED_JAMF_URL=""
CURRENT_USER=""
CURRENT_UID=""

touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
mkdir -p "$STATE_DIR"
chmod 755 "$STATE_DIR"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

get_console_user() {
  CURRENT_USER="$(stat -f%Su /dev/console 2>/dev/null || true)"
  if [[ -z "$CURRENT_USER" || "$CURRENT_USER" == "root" || "$CURRENT_USER" == "loginwindow" || "$CURRENT_USER" == "_mbsetupuser" ]]; then
    CURRENT_USER=""
    CURRENT_UID=""
    return 1
  fi
  CURRENT_UID="$(id -u "$CURRENT_USER" 2>/dev/null || true)"
  [[ -n "$CURRENT_UID" ]]
}

run_as_user() {
  [[ -n "$CURRENT_USER" && -n "$CURRENT_UID" ]] || return 1
  launchctl asuser "$CURRENT_UID" sudo -u "$CURRENT_USER" "$@"
}

show_user_message() {
  local title="$1"; local message="$2"; local icon="$3"
  if [[ -x "$DIALOG" && -n "$CURRENT_USER" ]]; then
    run_as_user "$DIALOG" --title "$title" --message "$message" --icon "$icon" --button1text "OK" --width 780 --height 460
  elif [[ -n "$CURRENT_USER" ]]; then
    run_as_user osascript -e "display dialog \"$message\" with title \"$title\" buttons {\"OK\"} default button \"OK\""
  else
    log "No GUI user for message: $title - $message"
  fi
}

get_jamf_url() {
  [[ -f "$JAMF_PLIST" ]] && defaults read "$JAMF_PLIST" jss_url 2>/dev/null || true
}

get_host_from_url() { echo "$1" | awk -F/ '{print $3}'; }
test_dns() { dscacheutil -q host -a name "$1" >/dev/null 2>&1; }
test_https() { curl -I --silent --show-error --connect-timeout 15 --max-time 30 "$1" >/dev/null 2>>"$LOG_FILE"; }

capture_jamf_url() {
  if [[ -n "$EXPECTED_JAMF_URL" ]]; then
    DISCOVERED_JAMF_URL="$EXPECTED_JAMF_URL"
  else
    DISCOVERED_JAMF_URL="$(get_jamf_url)"
  fi
  log "Captured Jamf URL: ${DISCOVERED_JAMF_URL:-not found}"
}

validate_pre_repair_connectivity() {
  log "Validating connectivity before repair."

  if ! test_dns "www.apple.com" || ! test_https "https://www.apple.com"; then
    log "General internet failed. Aborting repair to avoid false Jamf cleanup."
    show_user_message "Network Issue" "Internet connectivity is not stable. Jamf repair will not run until internet is working." "caution"
    return 1
  fi

  if command -v networkQuality >/dev/null 2>&1; then
    NQ_OUTPUT="$(networkQuality 2>&1)"
    echo "$NQ_OUTPUT" >> "$LOG_FILE"
    DOWNLINK="$(echo "$NQ_OUTPUT" | awk -F': ' '/Downlink capacity/ {print $2}' | awk '{print $1}' | tail -1)"
    DOWNLINK_INT="$(printf '%.0f' "$DOWNLINK" 2>/dev/null || true)"
    if [[ -n "${DOWNLINK_INT:-}" && "$DOWNLINK_INT" -lt "$BAD_SPEED_BELOW_MBPS" ]]; then
      log "Bad internet speed: ${DOWNLINK} Mbps. Aborting repair."
      show_user_message "Slow Internet" "Internet speed is below ${BAD_SPEED_BELOW_MBPS} Mbps. Jamf repair will not run on bad internet." "caution"
      return 1
    fi
  fi

  if [[ -n "$DISCOVERED_JAMF_URL" ]]; then
    JAMF_HOST="$(get_host_from_url "$DISCOVERED_JAMF_URL")"
    if [[ -n "$JAMF_HOST" ]]; then
      if ! test_dns "$JAMF_HOST" || ! test_https "$DISCOVERED_JAMF_URL"; then
        log "Jamf URL connectivity failed. Aborting destructive cleanup."
        show_user_message "Jamf Connectivity Issue" "Internet works, but Jamf URL is not reachable. Repair will not remove Jamf until Jamf connectivity is confirmed." "caution"
        return 1
      fi
    fi
  fi

  log "Connectivity checks passed."
  return 0
}

cleanup_jamf() {
  log "Starting Jamf cleanup."

  if [[ -x "$JAMF_BINARY" ]]; then
    log "Trying jamf removeMdmProfile."
    "$JAMF_BINARY" removeMdmProfile >> "$LOG_FILE" 2>&1 || log "removeMdmProfile failed or MDM profile is non-removable. Continuing."
    sleep 5

    log "Trying jamf removeFramework."
    "$JAMF_BINARY" removeFramework >> "$LOG_FILE" 2>&1 || log "removeFramework returned non-zero. Continuing manual cleanup."
  fi

  for item in /Library/LaunchDaemons/com.jamfsoftware.* /Library/LaunchAgents/com.jamfsoftware.*; do
    [[ -e "$item" ]] || continue
    launchctl bootout system "$item" >/dev/null 2>&1 || true
    launchctl unload "$item" >/dev/null 2>&1 || true
  done

  rm -rf \
    "/usr/local/jamf" \
    "/usr/local/bin/jamf" \
    "/Library/Application Support/JAMF" \
    "/Library/Application Support/Jamf" \
    "/Library/Application Support/com.jamfsoftware" \
    "/Library/Application Support/com.jamfsoftware.selfservice.mac" \
    "/Library/Preferences/com.jamfsoftware.jamf.plist" \
    "/Library/Preferences/com.jamfsoftware.selfservice.plist" \
    "/Library/Preferences/com.jamfsoftware.management.jamfAAD.plist" \
    "/Library/PrivilegedHelperTools/com.jamfsoftware.*" \
    "$SELF_SERVICE_APP" \
    "/Library/JSS" \
    /Library/Caches/com.jamfsoftware.* \
    /Library/LaunchDaemons/com.jamfsoftware.* \
    /Library/LaunchAgents/com.jamfsoftware.* \
    /var/db/receipts/com.jamfsoftware.* \
    /private/var/db/receipts/com.jamfsoftware.* 2>/dev/null || true

  # Local MDM removal may fail if ADE/non-removable; do not force beyond supported commands.
  profiles remove -type enrollment >> "$LOG_FILE" 2>&1 || log "profiles remove -type enrollment failed or profile is non-removable."
  log "Jamf cleanup completed."
}

make_user_admin() {
  get_console_user || { log "No valid console user found."; return 1; }
  if dseditgroup -o checkmember -m "$CURRENT_USER" admin | grep -qi yes; then
    log "$CURRENT_USER is already admin."
    return 0
  fi
  dseditgroup -o edit -a "$CURRENT_USER" -t user admin >> "$LOG_FILE" 2>&1
  if dseditgroup -o checkmember -m "$CURRENT_USER" admin | grep -qi yes; then
    log "$CURRENT_USER is now admin."
    return 0
  fi
  log "Failed to make $CURRENT_USER admin."
  return 1
}

turn_off_dnd_best_effort() {
  get_console_user || return 0
  run_as_user defaults -currentHost write com.apple.notificationcenterui doNotDisturb -bool false >/dev/null 2>&1 || true
  run_as_user defaults -currentHost delete com.apple.notificationcenterui doNotDisturbDate >/dev/null 2>&1 || true
  killall NotificationCenter >/dev/null 2>&1 || true
  log "DND/Focus disable attempted best-effort."
}

trigger_reenroll() {
  log "Triggering ADE enrollment renewal."
  profiles renew -type enrollment >> "$LOG_FILE" 2>&1 || log "profiles renew returned non-zero; prompt may still appear depending on ADE state."
  get_console_user || true
  if [[ -n "$CURRENT_USER" ]]; then
    run_as_user open "x-apple.systempreferences:com.apple.preferences.configurationprofiles" >/dev/null 2>&1 || true
    run_as_user osascript -e 'tell application "System Events" to key code 160' >/dev/null 2>&1 || true
  fi
}

show_reenroll_dialog() {
  get_console_user || return 0
  rm -f "$DIALOG_COMMAND_FILE"
  touch "$DIALOG_COMMAND_FILE"
  chmod 666 "$DIALOG_COMMAND_FILE"

  local msg="Your Mac is being re-enrolled into Device Management.

Please complete these steps:

1. Check Notification Center for Device Management / Remote Management.
2. Click the enrollment notification.
3. Install or accept the MDM profile.
4. If System Settings opens, approve Device Management / Profiles.
5. Because SSO customization is enabled, sign in with your company account when prompted.

You have 3 minutes to complete this step."

  if [[ -x "$DIALOG" ]]; then
    launchctl asuser "$CURRENT_UID" sudo -u "$CURRENT_USER" "$DIALOG" \
      --title "MDM Re-enrollment Required" \
      --message "$msg" \
      --icon "SF=gearshape.2.fill" \
      --button1text "I Completed Enrollment" \
      --progress 100 \
      --progresstext "Waiting for MDM enrollment..." \
      --commandfile "$DIALOG_COMMAND_FILE" \
      --ontop \
      --moveable \
      --width 820 \
      --height 640 &
    DIALOG_PID=$!

    for second in {1..180}; do
      progress=$(( second * 100 / REENROLL_GUIDE_SECONDS ))
      remaining=$(( REENROLL_GUIDE_SECONDS - second ))
      echo "progress: $progress" >> "$DIALOG_COMMAND_FILE"
      echo "progresstext: Complete MDM approval and SSO sign-in. ${remaining}s remaining." >> "$DIALOG_COMMAND_FILE"
      kill -0 "$DIALOG_PID" >/dev/null 2>&1 || break
      sleep 1
    done
    echo "quit:" >> "$DIALOG_COMMAND_FILE"
  else
    show_user_message "MDM Re-enrollment Required" "$msg" "caution"
    sleep "$REENROLL_GUIDE_SECONDS"
  fi
}

wait_for_mdm() {
  log "Waiting for MDM profile."
  for attempt in {1..24}; do
    STATUS="$(profiles status -type enrollment 2>&1)"
    echo "$STATUS" >> "$LOG_FILE"
    if echo "$STATUS" | grep -qi "MDM enrollment: Yes"; then
      log "MDM profile detected."
      show_user_message "Jamf / MDM Good" "MDM enrollment is complete. Jamf framework may install shortly after enrollment." "SF=checkmark.seal.fill"
      return 0
    fi
    sleep "$REENROLL_VALIDATION_SLEEP_SECONDS"
  done
  show_user_message "MDM Enrollment Not Completed" "Could not confirm a working MDM profile. Please check Notification Center, Device Management, and company SSO sign-in." "caution"
  return 1
}

main() {
  log "========== Starting full Jamf repair =========="
  get_console_user || true
  capture_jamf_url
  validate_pre_repair_connectivity || exit 1
  show_user_message "Jamf / MDM Repair Starting" "Repair is starting now. Please do not restart or shut down your Mac." "caution"
  cleanup_jamf
  make_user_admin || exit 1
  turn_off_dnd_best_effort
  validate_pre_repair_connectivity || exit 1
  trigger_reenroll
  show_reenroll_dialog
  wait_for_mdm
}

main "$@"
JAMF_SELF_HEAL_EOF_scripts_JamfHealthRepair_zsh

cat > "$HEALTHCHECK_DAEMON" <<'JAMF_SELF_HEAL_EOF_LaunchDaemons_com_bd_jamf_healthcheck_plist'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.bd.jamf.healthcheck</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>/Library/Application Support/BD/JamfRepair/JamfHealthCheckLite.zsh</string>
    </array>

    <key>StartInterval</key>
    <integer>3600</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/var/log/com.bd.jamf.healthcheck.out.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/com.bd.jamf.healthcheck.err.log</string>
</dict>
</plist>
JAMF_SELF_HEAL_EOF_LaunchDaemons_com_bd_jamf_healthcheck_plist

cat > "$REPAIR_RUNNER_DAEMON" <<'JAMF_SELF_HEAL_EOF_LaunchDaemons_com_bd_jamf_repair_runner_plist'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.bd.jamf.repair.runner</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>/Library/Application Support/BD/JamfRepair/JamfRepairRootRunner.zsh</string>
    </array>

    <key>WatchPaths</key>
    <array>
        <string>/var/db/com.bd.jamfrepair/run_repair_approved.flag</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/var/log/com.bd.jamf.repair.runner.out.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/com.bd.jamf.repair.runner.err.log</string>
</dict>
</plist>
JAMF_SELF_HEAL_EOF_LaunchDaemons_com_bd_jamf_repair_runner_plist

cat > "$USER_PROMPT_AGENT" <<'JAMF_SELF_HEAL_EOF_LaunchAgents_com_bd_jamf_repair_prompt_plist'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.bd.jamf.repair.prompt</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>/Library/Application Support/BD/JamfRepair/JamfRepairUserPrompt.zsh</string>
    </array>

    <key>StartInterval</key>
    <integer>900</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/com.bd.jamf.repair.prompt.out.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/com.bd.jamf.repair.prompt.err.log</string>
</dict>
</plist>
JAMF_SELF_HEAL_EOF_LaunchAgents_com_bd_jamf_repair_prompt_plist


log "Setting permissions."
chown -R root:wheel "$BASE_DIR" "$STATE_DIR"
chmod 755 "$BASE_DIR" "$STATE_DIR"
chmod 644 "$BASE_DIR/config.zsh"
chmod 755 "$BASE_DIR"/*.zsh

chown root:wheel "$HEALTHCHECK_DAEMON" "$REPAIR_RUNNER_DAEMON" "$USER_PROMPT_AGENT"
chmod 644 "$HEALTHCHECK_DAEMON" "$REPAIR_RUNNER_DAEMON" "$USER_PROMPT_AGENT"

# Ensure launchd can read state files created by root, and user agent can read state.
chmod 755 "$STATE_DIR"

# Reset stale locks but keep historical issue state.
rm -f "$STATE_DIR/user_prompt.lock" "$STATE_DIR/repair_running.lock"

unload_all
load_all

log "Running one immediate lightweight health check."
/bin/zsh "$BASE_DIR/JamfHealthCheckLite.zsh" >/dev/null 2>&1 || true

log "Install completed."
exit 0
