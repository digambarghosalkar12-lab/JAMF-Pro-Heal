#!/bin/zsh
# JamfHealthCheckLite.zsh
# Root hourly checker. Classifies issue correctly so bad internet is not treated as Jamf failure.

set -u

ORG_ID="bd"
STATE_DIR="/var/db/com.${ORG_ID}.jamfrepair"
LOG_FILE="/var/log/com.${ORG_ID}.jamfrepair.healthcheck.log"

JAMF_BINARY="/usr/local/bin/jamf"
JAMF_PLIST="/Library/Preferences/com.jamfsoftware.jamf.plist"

# EDIT THIS BEFORE PRODUCTION
EXPECTED_JAMF_URL="https://yourcompany.jamfcloud.com"
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
