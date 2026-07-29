# Support

ThermoFan is an experimental open-source utility. Support is provided through
GitHub issues on a best-effort basis.

## Before Opening an Issue

1. Return every fan to **Auto** in ThermoFan.
2. Quit and reopen the app.
3. Check **General > Hardware Helper**.
4. Build the latest version and run the diagnostics command:

```sh
dist/ThermoFan.app/Contents/MacOS/ThermoFan --diagnose
```

## Common Problems

### Hardware Helper is missing or needs an update

Use the action in **General > Hardware Helper**. Administrator authorization is
required once per helper version. Normal fan changes should not ask again.

### Hardware write failed

ThermoFan attempts to restore automatic mode after a failed write. Confirm the
Fans pane says **Hardware: Auto**, then run diagnostics and include the fan
section in a bug report.

### Temperatures look wrong

Disable **Show estimated fallback** to distinguish real SMC or PMU/HID readings
from load-based estimates. Include the sensor source and SMC key shown by the
app when reporting a mapping issue.

### My Mac shows no controllable fan

ThermoFan does not invent fan devices. Some Macs expose no compatible writable
fan keys, and fanless Macs have no fan to control.

## Diagnostic Privacy

Diagnostic output contains hardware model identifiers, sensor names, current
temperatures, and SMC keys. It does not intentionally include account
credentials, but review and trim unrelated lines before posting publicly.

Use the repository's issue forms for bugs, compatibility reports, and feature
requests. Use private vulnerability reporting for security issues.
