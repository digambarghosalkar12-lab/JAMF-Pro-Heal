#!/bin/zsh
# Install Jamf Self-Heal project files and load launchd jobs.

set -euo pipefail

BASE_DIR="/Library/Application Support/BD/JamfRepair"
STATE_DIR="/var/db/com.bd.jamfrepair"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$BASE_DIR" "$STATE_DIR"

cp "$SRC_DIR/scripts/"*.zsh "$BASE_DIR/"
cp "$SRC_DIR/LaunchDaemons/"*.plist /Library/LaunchDaemons/
cp "$SRC_DIR/LaunchAgents/"*.plist /Library/LaunchAgents/

chown -R root:wheel "$BASE_DIR" "$STATE_DIR"
chmod 755 "$BASE_DIR" "$STATE_DIR"
chmod 755 "$BASE_DIR"/*.zsh

chown root:wheel /Library/LaunchDaemons/com.bd.jamf.healthcheck.plist
chown root:wheel /Library/LaunchDaemons/com.bd.jamf.repair.runner.plist
chmod 644 /Library/LaunchDaemons/com.bd.jamf.healthcheck.plist
chmod 644 /Library/LaunchDaemons/com.bd.jamf.repair.runner.plist

chown root:wheel /Library/LaunchAgents/com.bd.jamf.repair.prompt.plist
chmod 644 /Library/LaunchAgents/com.bd.jamf.repair.prompt.plist

launchctl bootout system /Library/LaunchDaemons/com.bd.jamf.healthcheck.plist 2>/dev/null || true
launchctl bootout system /Library/LaunchDaemons/com.bd.jamf.repair.runner.plist 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.bd.jamf.healthcheck.plist
launchctl bootstrap system /Library/LaunchDaemons/com.bd.jamf.repair.runner.plist
launchctl kickstart -k system/com.bd.jamf.healthcheck || true

CURRENT_USER="$(stat -f%Su /dev/console 2>/dev/null || true)"
CURRENT_UID="$(id -u "$CURRENT_USER" 2>/dev/null || true)"
if [[ -n "$CURRENT_UID" && "$CURRENT_USER" != "root" && "$CURRENT_USER" != "loginwindow" ]]; then
  launchctl bootout gui/"$CURRENT_UID" /Library/LaunchAgents/com.bd.jamf.repair.prompt.plist 2>/dev/null || true
  launchctl bootstrap gui/"$CURRENT_UID" /Library/LaunchAgents/com.bd.jamf.repair.prompt.plist
  launchctl kickstart -k gui/"$CURRENT_UID"/com.bd.jamf.repair.prompt || true
fi

echo "Installed Jamf Self-Heal."
