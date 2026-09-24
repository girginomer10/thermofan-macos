# Support

ThermoFan is an experimental open-source utility. Support is provided through
GitHub issues on a best-effort basis.

## Before Opening an Issue

1. Return every fan to **Auto** in ThermoFan.
2. Quit and reopen the app.
3. Check **General > Hardware Helper** in Settings and write down the exact
   state it shows (it is also listed under **About**). Include that state in
   your report, because the diagnostics command does not print it.
4. Build the latest version and run the diagnostics command:

```sh
dist/ThermoFan.app/Contents/MacOS/ThermoFan --diagnose
```

## Common Problems

### Hardware Helper is missing, waiting for approval, or needs an update

Runtime helper authorization requires a Developer ID signed ThermoFan build in
`/Applications`; then use the action in **General > Hardware Helper**. If macOS
opens **System Settings > General > Login Items**, approve ThermoFan and retry.
Normal fan changes should not ask again after approval. Any public download must
also be notarized and pass the Gatekeeper release gates; no public 0.3.0 binary
has completed those gates yet.

An ad-hoc source build has no Developer ID Team ID and is intentionally
monitoring-only; it cannot register the privileged daemon.

### Other Hardware Helper states

- **Monitoring only**: this build is ad-hoc, not Developer ID signed, or lacks
  the embedded helper, so it can read sensors and fans but never control them.
- **Move to Applications**: the signed app is not running from
  `/Applications/ThermoFan.app`; move it there and relaunch it.
- **Inactive login session**: this login session is not the active local
  console user (for example after fast user switching); only that user can
  control fans, and monitoring keeps working here.
- **Helper not responding**: the registered helper did not answer in time,
  often because it is still verifying recovery; wait a few seconds, then retry
  from **General > Hardware Helper**.

### Legacy helper security upgrade required

Do not use fan control until migration completes. ThermoFan automatically starts
the authenticated service registration and opens Login Items when approval is
needed. Approve it, return to ThermoFan, and retry **Secure Upgrade**. The warning
disappears only after the old exact helper paths and processes are gone and a
final Auto recovery has been verified.

### Hardware recovery requires attention

Do not retry manual control. Select **Return to Auto** or **Retry Recovery** and
confirm every fan reports **Hardware: Auto**. **Retry Recovery** only asks the
Hardware Helper to re-verify that ThermoFan-owned fans are back in Auto. It
never writes a manual fan target and never registers, unregisters, or
re-registers the service. Protocol 9 keeps writes blocked when startup,
connection, process-exit, heartbeat, or daemon-termination recovery cannot be
verified.

### Uninstalling the Hardware Helper

Use **General > Hardware Helper > Unregister** before deleting the app. If Login
Items approval was revoked, re-enable it first; this lets the daemon prove Auto
before macOS removes the registration. A missing/broken `.notFound` service is
not treated as successfully unregistered.

### Hardware write failed

ThermoFan attempts to restore automatic mode after a failed write. Confirm the
Fans pane says **Hardware: Auto**, then run diagnostics. In the bug report,
include the diagnostics fan section, the Hardware Helper state shown in
Settings (diagnostics do not print it), and whether the app was force-quit,
slept, or changed users.

### Temperatures look wrong

Disable **Show estimated fallback** to distinguish real SMC or PMU/HID readings
from load-based estimates. Include the sensor source and SMC key shown by the
app when reporting a mapping issue.

### My Mac shows no controllable fan

ThermoFan does not invent fan devices. Some Macs expose no compatible writable
fan keys, and fanless Macs have no fan to control.

M1-M5 support is capability-detected and fail-closed; it is not yet a claim of
physical write/recovery verification on every M-series model. See the current
[compatibility matrix](docs/COMPATIBILITY.md).

## Diagnostic Privacy

Diagnostic output contains hardware model identifiers, sensor names, current
temperatures, and SMC keys. It does not intentionally include account
credentials, but review and trim unrelated lines before posting publicly.

Use the repository's issue forms for bugs, compatibility reports, and feature
requests. Use private vulnerability reporting for security issues.
