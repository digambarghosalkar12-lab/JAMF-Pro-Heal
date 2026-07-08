# Self-Healing Jamf / MDM Repair Button for macOS using Support App

> A practical macOS endpoint-support workflow that lets users run a guided Jamf health check and MDM re-enrollment repair from the Root3 Support App menu bar.

![Architecture](assets/architecture.svg)

## What we are building

This project builds a **self-service Jamf health repair workflow** for managed macOS devices.

The user opens **Support App**, clicks **Repair Jamf / MDM**, and a privileged script runs as root. The script validates whether Jamf and MDM are working correctly. If everything is healthy, the user gets a simple **Jamf is good** confirmation. If the device is unhealthy, the script cleans broken Jamf components, prepares the Mac for re-enrollment, triggers Automated Device Enrollment renewal, and guides the user through the enrollment popup and SSO sign-in flow.

The goal is not to replace Jamf Pro administration. The goal is to reduce help-desk effort when a Mac is stuck in a bad management state and the user can still interact with the device.

## Why we are doing this

In enterprise macOS environments, Jamf management can fail for many reasons:

- Jamf binary is missing or broken.
- Jamf check-in fails.
- Inventory recon fails.
- MDM profile is missing, stale, or not responding.
- Network, DNS, SSL, or proxy issues block Jamf communication.
- User ignored or missed the MDM enrollment notification.
- Device has Jamf files left behind but is not properly managed.
- Bootstrap token or MDM trust state is not healthy.

Normally, this becomes a manual help-desk task: remote into the Mac, check logs, remove broken framework pieces, trigger enrollment again, and guide the user to approve the MDM profile.

This workflow packages those steps into a controlled **Support App action** so the user or support team can start the repair from a trusted menu bar app.

## What the user gets

The end user gets a simple experience:

1. Open **Support App**.
2. Click **Repair Jamf / MDM**.
3. If Jamf is healthy, see **Jamf is good**.
4. If repair is needed, follow the Swift Dialog instructions.
5. Accept the MDM / Remote Management popup.
6. Complete company SSO sign-in.
7. Device is validated again and marked good.

## What IT gets

IT gets a repeatable workflow that:

- Validates Jamf health locally.
- Checks internet speed before repair.
- Tests DNS, SSL, and Jamf reachability.
- Avoids running generic production policies accidentally.
- Uses a safe custom Jamf policy trigger if configured.
- Removes Jamf framework using the supported Jamf command when possible.
- Attempts MDM cleanup carefully and logs if the profile is non-removable.
- Makes the current logged-in user admin only when needed for enrollment approval.
- Guides the user through the 3-minute MDM enrollment window.
- Logs all activity to `/var/log/jamf_health_repair.log`.

## Workflow diagram

![Workflow](assets/workflow.svg)

## High-level flow

```text
User clicks Support App button
        ↓
Support App runs privileged script as root
        ↓
Script validates Jamf, MDM, network, speed, disk, logs
        ↓
If healthy:
    Show “Jamf is good”
        ↓
If unhealthy:
    Try MDM profile cleanup
    Remove Jamf framework/components
    Make current logged-in user admin
    Turn off DND / Focus best-effort
    Validate internet + Jamf connectivity
    Run profiles renew -type enrollment
    Open Device Management / Profiles
    Show Swift Dialog 3-minute guide
    User accepts MDM popup and completes SSO
    Validate MDM profile
    Mark device good
```

## Internet speed logic

The script uses macOS `networkQuality` and parses **Downlink capacity**.

| Speed | Status |
|---|---|
| Below 50 Mbps | Bad |
| 50 Mbps to 200 Mbps | Average |
| Above 200 Mbps | Good |

A speed below 50 Mbps is treated as a failure because MDM re-enrollment, Jamf framework download, package installation, and SSO workflows can become unreliable on weak connections.

## Important design decisions

### 1. Do not run generic `jamf policy`

Running this command blindly can trigger real production policies:

```bash
jamf policy
```

Instead, the script uses a dedicated custom trigger:

```bash
jamf policy -event healthcheck
```

If you do not have a safe policy trigger, keep this variable empty:

```bash
HEALTHCHECK_POLICY_TRIGGER=""
```

### 2. Capture Jamf URL before cleanup

The script captures the Jamf Pro URL before deleting the Jamf plist. This avoids breaking pre-reenrollment connectivity tests after cleanup.

```bash
DISCOVERED_JAMF_URL="$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url 2>/dev/null)"
```

For production, hardcode your Jamf URL:

```bash
EXPECTED_JAMF_URL="https://yourcompany.jamfcloud.com"
```

### 3. Do not force-remove non-removable MDM profiles

On ADE-enrolled Macs, the MDM profile may be non-removable. The script attempts supported cleanup, but if macOS blocks removal, the script logs the condition and continues carefully.

### 4. Use Support App `PrivilegedScript`

Support App can run privileged scripts through its helper tool. The privileged script path must be deployed through a configuration profile, not just configured with local `defaults write`.

### 5. User guidance is required

`profiles renew -type enrollment` can trigger a Remote Management / Device Management prompt, but the user may still need to accept the enrollment popup and complete company SSO sign-in. The script uses Swift Dialog to guide the user during this window.

## Repository structure

```text
jamf-supportapp-health-repair/
├── README.md
├── assets/
│   ├── architecture.svg
│   └── workflow.svg
├── scripts/
│   └── JamfHealthRepair.zsh
├── supportapp/
│   └── supportapp-config.mobileconfig
└── packaging/
    └── postinstall.sh
```

## Deployment path

Deploy the repair script here:

```bash
/Library/Application Support/BD/Support/JamfHealthRepair.zsh
```

Set ownership and permissions:

```bash
sudo chown root:wheel "/Library/Application Support/BD/Support/JamfHealthRepair.zsh"
sudo chmod 755 "/Library/Application Support/BD/Support/JamfHealthRepair.zsh"
```

## Support App button configuration

Use the Support App preference domain:

```text
nl.root3.support
```

Example row item:

```xml
<key>Rows</key>
<array>
    <dict>
        <key>Items</key>
        <array>
            <dict>
                <key>Type</key>
                <string>ButtonMedium</string>

                <key>Title</key>
                <string>Repair Jamf / MDM</string>

                <key>Subtitle</key>
                <string>Validate and repair device management</string>

                <key>Symbol</key>
                <string>stethoscope</string>

                <key>ActionType</key>
                <string>PrivilegedScript</string>

                <key>Action</key>
                <string>/Library/Application Support/BD/Support/JamfHealthRepair.zsh</string>
            </dict>
        </array>
    </dict>
</array>
```

## Packaging postinstall

```bash
#!/bin/bash

SCRIPT_PATH="/Library/Application Support/BD/Support/JamfHealthRepair.zsh"

mkdir -p "$(dirname "$SCRIPT_PATH")"
chown root:wheel "$SCRIPT_PATH"
chmod 755 "$SCRIPT_PATH"

exit 0
```

## Jamf Pro deployment plan

Create these Jamf Pro items:

### 1. Package: Support App

Deploy the latest Support App package to the target Macs.

### 2. Package: Jamf repair script

Package the file:

```bash
/Library/Application Support/BD/Support/JamfHealthRepair.zsh
```

Make sure the postinstall sets:

```bash
root:wheel
755
```

### 3. Configuration Profile: Support App configuration

Payload domain:

```text
nl.root3.support
```

Include the button with:

```text
ActionType = PrivilegedScript
Action = /Library/Application Support/BD/Support/JamfHealthRepair.zsh
```

### 4. PPPC profile

Deploy PPPC permissions for Support App and its privileged helper if your script needs access to protected areas.

Common access requirements:

- Full Disk Access / SystemPolicyAllFiles
- Files under `/Library`
- Logs under `/var/log`
- Device profiles and management-related operations

### 5. Optional Jamf policy trigger

Create a safe custom trigger policy named:

```text
healthcheck
```

The policy should do something harmless, such as echoing a status or updating a small extension value. Do not scope install/remove actions to this trigger unless intentionally designed.

## Script configuration variables

Edit these before production:

```bash
EXPECTED_JAMF_URL="https://yourcompany.jamfcloud.com"
REQUIRE_JAMF_URL_FOR_REENROLL="false"
HEALTHCHECK_POLICY_TRIGGER="healthcheck"
BAD_SPEED_BELOW_MBPS=50
GOOD_SPEED_ABOVE_MBPS=200
REENROLL_GUIDE_SECONDS=180
MIN_FREE_SPACE_GB=15
```

## User-facing Swift Dialog message

The repair flow tells the user:

```text
Your Mac is being re-enrolled into MDM.

Please complete these steps:

1. Check Notification Center for the Device Management / Remote Management notification.
2. Click the enrollment notification.
3. Install or accept the MDM management profile.
4. If System Settings opens, go to Device Management / Profiles and approve the profile.
5. Because SSO customization is enabled, you may get a company sign-in popup after profile installation.
6. Sign in using your company account to complete enrollment.

You have 3 minutes to complete this step.
```

## Testing checklist

Before deploying widely, test on a small pilot group.

| Test | Expected result |
|---|---|
| Healthy Jamf Mac | Shows “Jamf is good” |
| Mac with missing Jamf binary | Starts repair flow |
| Mac with bad network | Stops before re-enrollment and shows network warning |
| Mac with slow internet below 50 Mbps | Fails speed validation |
| Mac with ADE available | Shows Remote Management / Device Management prompt |
| User accepts MDM profile | MDM profile detected after enrollment |
| SSO customization enabled | User gets company sign-in popup |
| No Support App helper | PrivilegedScript fails; fix Support App helper deployment |
| Script wrong permissions | Support App does not run script; fix root:wheel and 755 |

## Logs

Main log:

```bash
/var/log/jamf_health_repair.log
```

Useful local checks:

```bash
profiles status -type enrollment
profiles status -type bootstraptoken
/usr/local/bin/jamf checkJSSConnection
/usr/local/bin/jamf recon
networkQuality
```

## Security notes

This workflow is powerful because it can remove local Jamf components and trigger re-enrollment. Use it carefully.

Recommended controls:

- Scope Support App repair button only to trusted/internal Macs.
- Use a signed or checksum-validated script package.
- Keep the script owned by `root:wheel` with `755` permissions.
- Avoid writable script paths.
- Do not store secrets in the script.
- Avoid generic `jamf policy` execution.
- Log actions clearly.
- Pilot before production rollout.

## Limitations

This script cannot magically repair every MDM issue. Known limitations:

- A non-removable ADE MDM profile may require the **Remove MDM Profile** command from Jamf Pro.
- If the Mac is not assigned to the correct MDM server in Apple Business Manager, ADE renewal will not enroll correctly.
- If the user does not accept the enrollment popup, enrollment cannot complete.
- If SSO customization fails, user sign-in may block enrollment completion.
- If network, DNS, SSL inspection, or proxy blocks Jamf/Apple traffic, re-enrollment can fail.
- If Support App privileged helper is not installed or approved, the action cannot run as root.

## References

- Root3 Support App GitHub: https://github.com/root3nl/SupportApp
- Support App configuration wiki: https://github.com/root3nl/SupportApp/wiki/Configuration
- Support App privileged scripts wiki: https://github.com/root3nl/SupportApp/wiki/Privileged-Scripts
- Apple Automated Device Enrollment: https://support.apple.com/guide/deployment/automated-device-enrollment-and-device-management-dep73069dd57/web
- Jamf removing non-removable MDM profiles: https://support.jamf.com/en/articles/11016553-removing-jamf-pro-non-removable-mdm-profiles
- Jamf Pro unmanaging computers: https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Unmanaging_Computers
- Swift Dialog command file updates: https://github.com/swiftDialog/swiftDialog/wiki/Updating-Dialog-with-new-content

## Codex prompt to generate or improve the script

Use this prompt in Codex if you want it to generate or refine the script:

```text
Build a production-ready macOS zsh script for Jamf Pro health validation and self-repair. The script will be launched from Root3 Support App as a PrivilegedScript. It must run as root, log to /var/log/jamf_health_repair.log, detect the current logged-in console user, validate Jamf binary, Jamf plist, Jamf Pro URL, DNS, HTTPS/SSL, networkQuality downlink speed, MDM enrollment profile, User Approved MDM, bootstrap token, jamf checkJSSConnection, jamf recon, optional safe custom trigger jamf policy -event healthcheck, Self Service app, Jamf LaunchDaemons, disk space, network time, and recent jamf.log errors.

Speed thresholds: below 50 Mbps = bad/fail, 50-200 Mbps = average/pass, above 200 Mbps = good/pass.

If all critical checks pass, show Swift Dialog message: Jamf is good.

If checks fail, capture Jamf URL before cleanup, try jamf removeMdmProfile while Jamf binary still exists, try profiles remove -type enrollment, run jamf removeFramework, remove Jamf leftover files, make current logged-in user local admin, turn off Focus/DND best-effort, run proactive connectivity tests before re-enrollment, trigger profiles renew -type enrollment, open System Settings Device Management / Profiles, show Swift Dialog with a 3-minute progress bar guiding user to accept the Remote Management / MDM enrollment popup and complete SSO customization sign-in, then validate profiles status -type enrollment until MDM enrollment is Yes. If MDM profile is detected, mark device good. Optionally wait for Jamf binary to reinstall.

Do not run generic jamf policy. Only use a configurable safe custom trigger. Do not use curl -k for primary SSL validation. Treat ADE non-removable profile failure as warning, not destructive force removal. Keep all variables at top.
```
