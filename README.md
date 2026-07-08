# Jamf Self-Heal for macOS

This project creates a Jamf / MDM self-healing workflow for macOS.

## What it does

- Checks Jamf health every 1 hour using a LaunchDaemon.
- Separates real Jamf issues from bad internet, slow internet, DNS, proxy, VPN, or Jamf Cloud reachability issues.
- Shows only a native notification for the first 2 days.
- If a repairable Jamf/MDM issue remains for 2 days, shows a SwiftDialog popup with **Run Repair Now**.
- Runs the full repair script as root only after user approval.
- Guides the user through ADE / Remote Management re-enrollment and SSO sign-in.

## Why this design

A LaunchDaemon is good for root-level background checks, but it should not directly show GUI prompts. A LaunchAgent runs in the user session and can show notifications/dialogs. This project uses both.

The repair script is not triggered for bad internet. This avoids accidentally removing Jamf when the user is on weak Wi-Fi, captive portal, VPN/proxy issue, or temporary Jamf reachability issue.

## Required external dependency

SwiftDialog is required for the 2-day popup workflow:

```bash
/usr/local/bin/dialog
```

Native macOS notification is used during the first 2 days.

## Files

```text
scripts/JamfHealthCheckLite.zsh       # hourly root checker
scripts/JamfRepairUserPrompt.zsh      # user LaunchAgent notification/dialog
scripts/JamfRepairRootRunner.zsh      # root runner after approval
scripts/JamfHealthRepair.zsh          # full repair and re-enrollment workflow
LaunchDaemons/com.bd.jamf.healthcheck.plist
LaunchDaemons/com.bd.jamf.repair.runner.plist
LaunchAgents/com.bd.jamf.repair.prompt.plist
install.sh
uninstall.sh
```

## Production settings

Edit these in both `JamfHealthCheckLite.zsh` and `JamfHealthRepair.zsh`:

```zsh
EXPECTED_JAMF_URL="https://yourcompany.jamfcloud.com"
BAD_SPEED_BELOW_MBPS=50
```

## Deployment paths

```text
/Library/Application Support/BD/JamfRepair/
/Library/LaunchDaemons/com.bd.jamf.healthcheck.plist
/Library/LaunchDaemons/com.bd.jamf.repair.runner.plist
/Library/LaunchAgents/com.bd.jamf.repair.prompt.plist
/var/db/com.bd.jamfrepair/
```

## How the workflow works

```text
Every 1 hour
  ↓
LaunchDaemon runs JamfHealthCheckLite.zsh
  ↓
Classifies issue:
  - NETWORK_ISSUE              no repair
  - SLOW_INTERNET              no repair
  - JAMF_CONNECTIVITY_ISSUE    no repair
  - JAMF_CLIENT_BROKEN         repair allowed
  - MDM_PROFILE_MISSING        repair allowed
  - JAMF_CLIENT_OR_TRUST_ISSUE repair allowed
  ↓
LaunchAgent checks every 15 minutes
  ↓
First 2 days: native notification only
  ↓
After 2 days: SwiftDialog popup
  ↓
User clicks Run Repair Now
  ↓
Root LaunchDaemon runs JamfHealthRepair.zsh
```

## Install

```bash
sudo ./install.sh
```

## Uninstall

```bash
sudo ./uninstall.sh
```

## Testing

Force a repairable issue flag:

```bash
sudo mkdir -p /var/db/com.bd.jamfrepair
sudo sh -c 'echo JAMF_CLIENT_BROKEN > /var/db/com.bd.jamfrepair/issue_type'
sudo sh -c 'echo Jamf binary test failure > /var/db/com.bd.jamfrepair/issue_reason'
sudo sh -c 'echo true > /var/db/com.bd.jamfrepair/issue_repair_allowed'
sudo sh -c "echo $(( $(date +%s) - 172900 )) > /var/db/com.bd.jamfrepair/issue_first_detected_epoch"
```

Then kickstart the user prompt LaunchAgent:

```bash
USER_NAME="$(stat -f%Su /dev/console)"
USER_ID="$(id -u "$USER_NAME")"
launchctl kickstart -k gui/$USER_ID/com.bd.jamf.repair.prompt
```

## Logs

```text
/var/log/com.bd.jamfrepair.healthcheck.log
/tmp/com.bd.jamfrepair.userprompt.log
/var/log/com.bd.jamfrepair.runner.log
/var/log/com.bd.jamfrepair.fullrepair.log
```

## Safety behavior

The repair will not run for:

- bad internet
- slow internet below threshold
- Jamf URL DNS failure
- Jamf URL HTTPS/SSL failure

The repair only runs for local Jamf or MDM client conditions after user approval.
