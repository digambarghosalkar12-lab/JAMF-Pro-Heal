#!/bin/zsh
# JamfHealthRepair.zsh
# Full root repair script. Triggered only after user approves via SwiftDialog after 2 days.

set -u

ORG_ID="bd"
STATE_DIR="/var/db/com.${ORG_ID}.jamfrepair"
LOG_FILE="/var/log/com.${ORG_ID}.jamfrepair.fullrepair.log"
DIALOG="/usr/local/bin/dialog"
DIALOG_COMMAND_FILE="/var/tmp/com.${ORG_ID}.jamfrepair.reenroll.dialog"

JAMF_BINARY="/usr/local/bin/jamf"
JAMF_PLIST="/Library/Preferences/com.jamfsoftware.jamf.plist"
SELF_SERVICE_APP="/Applications/Self Service.app"

# EDIT THIS BEFORE PRODUCTION
EXPECTED_JAMF_URL="https://yourcompany.jamfcloud.com"
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
