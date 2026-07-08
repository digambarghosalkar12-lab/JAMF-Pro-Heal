#!/bin/zsh
# Uninstall Jamf Self-Heal project files and launchd jobs.

BASE_DIR="/Library/Application Support/BD/JamfRepair"
STATE_DIR="/var/db/com.bd.jamfrepair"

CURRENT_USER="$(stat -f%Su /dev/console 2>/dev/null || true)"
CURRENT_UID="$(id -u "$CURRENT_USER" 2>/dev/null || true)"
if [[ -n "$CURRENT_UID" && "$CURRENT_USER" != "root" && "$CURRENT_USER" != "loginwindow" ]]; then
  launchctl bootout gui/"$CURRENT_UID" /Library/LaunchAgents/com.bd.jamf.repair.prompt.plist 2>/dev/null || true
fi

launchctl bootout system /Library/LaunchDaemons/com.bd.jamf.healthcheck.plist 2>/dev/null || true
launchctl bootout system /Library/LaunchDaemons/com.bd.jamf.repair.runner.plist 2>/dev/null || true

rm -f /Library/LaunchDaemons/com.bd.jamf.healthcheck.plist
rm -f /Library/LaunchDaemons/com.bd.jamf.repair.runner.plist
rm -f /Library/LaunchAgents/com.bd.jamf.repair.prompt.plist
rm -rf "$BASE_DIR"
rm -rf "$STATE_DIR"

echo "Uninstalled Jamf Self-Heal."
