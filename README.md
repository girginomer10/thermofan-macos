<div align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="ThermoFan app icon">
  <h1>ThermoFan</h1>
  <p>A native macOS menu bar app for real thermal monitoring and verified fan control.</p>

  [![CI](https://github.com/girginomer10/thermofan-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/girginomer10/thermofan-macos/actions/workflows/ci.yml)
  [![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple)](https://support.apple.com/macos)
  [![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org)
  [![MIT License](https://img.shields.io/badge/license-MIT-2ea44f)](LICENSE)
</div>

ThermoFan reads available SMC and Apple PMU/HID temperature sensors, discovers
real fans, and lets you use automatic, fixed-RPM, or sensor-linked curve
control. Hardware changes are not reported as successful until the target and
mode have been read back from the SMC.

> [!WARNING]
> ThermoFan is experimental system software. Apple's SMC interfaces are private,
> vary by Mac model, and may change with macOS updates. Manual fan control can
> affect cooling, noise, component life, and system stability. Read
> [SAFETY.md](docs/SAFETY.md) before enabling fixed or curve control.

## Highlights

- Real SMC fan discovery with current, minimum, maximum, and target RPM
- Runtime detection of uppercase and lowercase Apple Silicon fan-mode keys
- Monitoring-only fallback when a firmware control surface is not verified
- Real SMC and Apple PMU/HID temperature readings
- Automatic, fixed-RPM, and temperature-curve fan modes
- Drag-editable curve graph with labeled temperature and RPM axes
- Direct numeric editing for every curve point
- Built-in CPU, GPU, and system hotspot indexes
- User-defined hottest-value or average indexes
- Stable sensor rows for intermittently sleeping SMC core keys, with stale
  values clearly marked as last readings
- Read-back verification after every hardware write
- One-time macOS approval for an embedded `SMAppService` Hardware Helper
- Best-effort automatic-mode recovery on normal quit, crash, force-quit, and
  failed writes
- Presets, favorites, hidden sensors, menu bar selections, launch at login, and
  local persistence
- No analytics, telemetry, accounts, cloud sync, or background network requests

## Compatibility

| Item | Status |
| --- | --- |
| Minimum OS | macOS 14 |
| Distribution architecture | arm64 (Apple Silicon M-series) |
| Software capability coverage | M1-M5 fanless, one-fan, and two-fan firmware shapes |
| Current read-only validation | Mac16,11 with Apple M4 Pro |
| Validated OS | macOS 26.5.1 |
| Observed fan layout | One fan, 1,000-4,900 RPM; protocol 9 physical write/recovery acceptance pending |

Compatibility is intentionally stated narrowly. A successful build does not
prove that a new Mac exposes compatible writable SMC fan keys. See the
[M-series compatibility matrix](docs/COMPATIBILITY.md) and report verified models through the
[hardware compatibility issue form](https://github.com/girginomer10/thermofan-macos/issues/new?template=hardware_compatibility.yml).

ThermoFan is a direct-distribution utility, not a Mac App Store product.

## Build and Install

Requirements:

- macOS 14 or newer
- Xcode command line tools with Swift 6

```sh
git clone https://github.com/girginomer10/thermofan-macos.git
cd thermofan-macos
./scripts/build_app.sh
rm -rf /Applications/ThermoFan.app
ditto dist/ThermoFan.app /Applications/ThermoFan.app
open /Applications/ThermoFan.app
```

Quit ThermoFan before installing. Remove the old copy first because `ditto`
merges into an existing bundle instead of replacing it. Leftover files from the
old version would sit inside the newly signed bundle and break its code
signature, so `codesign --verify --deep --strict` fails and macOS can refuse to
launch the app or its helper. If a Developer ID build with a registered
Hardware Helper is installed, choose **Unregister** in that build before you
replace it (see [Uninstall](#uninstall)). An ad-hoc source build cannot run
the authenticated removal.

The build script creates an arm64, Hardened Runtime app bundle with an ad-hoc
development signature at `dist/ThermoFan.app`. Ad-hoc builds deliberately stay
monitoring-only because they have no Developer ID Team ID. The guarded
Developer ID/notarization workflow and its remaining public-release gates are
documented in
[Direct Distribution](docs/DISTRIBUTION.md).

The signed release embeds its root daemon and launchd registration file at:

```text
ThermoFan.app/Contents/MacOS/ThermoFanHelper
ThermoFan.app/Contents/Library/LaunchDaemons/io.github.girginomer10.ThermoFan.helper.plist
```

Move ThermoFan to `/Applications`, use **General > Hardware Helper**, then
approve ThermoFan under **System Settings > General > Login Items** when macOS
asks. `SMAppService` registers the embedded LaunchDaemon; ThermoFan never copies
or installs a setuid executable. The app and daemon mutually require the exact
Developer ID identifiers and Team ID before protocol 9 accepts any fan command.
If an older privileged helper is detected, ThermoFan starts a required security
migration and keeps manual control blocked until macOS approval, legacy-process
drain, exact-path removal, and a final Auto recovery are all verified.

## Development

Run the app directly:

```sh
swift run ThermoFan
```

Run tests:

```sh
swift test
```

Build the distributable app bundle:

```sh
./scripts/build_app.sh
codesign --verify --deep --strict dist/ThermoFan.app
```

Read-only hardware diagnostics:

```sh
dist/ThermoFan.app/Contents/MacOS/ThermoFan --diagnose
```

Diagnostics report the Mac model, available sensors, fan ranges, and selected
raw SMC keys. They do not write fan settings. Review the output before posting
it publicly because hardware identifiers and temperature readings are included.

## How Fan Control Works

1. A UI change is staged and marked as pending.
2. `Apply to Hardware` requires the Developer ID signed Hardware Helper to be
   registered and approved by macOS.
3. The app and root daemon authenticate each other over NSXPC. The daemon also
   requires the active local graphical console user and arms a process-exit
   watchdog before acknowledging a manual-control lease.
4. The daemon reads the fan count and hardware RPM range.
5. It discovers the firmware's per-fan mode key; an unknown control surface is
   left read-only.
6. For fixed or curve mode, it enters manual mode, writes the target, and reads
   both values back.
7. A mismatch returns the fan to automatic mode and reports an error.
8. Curve mode recalculates the target from its linked sensor or index as
   temperatures change.

The daemon runs only on the local Mac. Its narrow protocol, lifecycle, and
trust boundaries are documented in [ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Data and Privacy

Preferences are stored locally in:

```text
~/Library/Application Support/ThermoFan/state.json
```

ThermoFan does not collect or transmit sensor readings. The two links in the
About pane open this GitHub repository only when clicked.

## Uninstall

Open **General > Hardware Helper** and choose **Unregister**. ThermoFan first
verifies Auto through the daemon's stable recovery protocol, waits until macOS
reports the service as not registered, and only then reports success. Quit the
app and remove it:

```sh
rm -rf /Applications/ThermoFan.app
```

To remove preferences too:

```sh
rm -rf "$HOME/Library/Application Support/ThermoFan"
```

Do not use the Login Items toggle alone as an uninstall step. If approval was
revoked, re-enable ThermoFan there first so the daemon can prove Auto, then use
**Unregister** in the app.

## Project

- [Contributing](CONTRIBUTING.md)
- [Support and troubleshooting](SUPPORT.md)
- [Security policy](SECURITY.md)
- [Safety model](docs/SAFETY.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Apple Silicon compatibility](docs/COMPATIBILITY.md)
- [Direct distribution](docs/DISTRIBUTION.md)
- [Changelog](CHANGELOG.md)

ThermoFan is released under the [MIT License](LICENSE).
