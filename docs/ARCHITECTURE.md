# Architecture

ThermoFan is a SwiftUI menu bar application with a small C helper for privileged
SMC fan writes. All sensor processing and persistence stay on the local Mac.

## Components

| Area | Responsibility |
| --- | --- |
| `ThermoFanApp.swift` | App lifecycle, settings window, menu bar scene |
| `ThermalStore.swift` | Application state, refresh loop, curves, presets, recovery |
| `HardwareProbe.swift` | Hardware discovery, persistence, helper installation and invocation |
| `SMCClient.swift` | Typed reads and writes through AppleSMC IOKit user client |
| `HIDTemperatureReader.swift` | Apple PMU/HID temperature discovery |
| `FanCurveMath.swift` | Curve normalization and interpolation |
| `Models.swift` | Persisted and runtime domain models |
| `Views.swift` | Menu bar and settings UI |
| `CommandLineEntrypoint.swift` | Read-only diagnostics |
| `ThermoFanHelper/main.c` | Bounded privileged fan commands and watchdog |

## Read Path

1. `HardwareProbe` opens the AppleSMC service when available.
2. Known, model-appropriate SMC keys are decoded by their declared data type.
3. Apple PMU/HID temperatures supplement SMC readings.
4. `ThermalStore` creates built-in and custom indexes from real sensor values.
5. SwiftUI observes the store and renders the menu bar and settings views.

Estimated fallback temperatures are separate, marked as estimated, and disabled
by default.

## Write Path

1. The user stages automatic, fixed, or curve mode in the UI.
2. `ThermalStore` snapshots the staged fan setting away from the main actor.
3. `FanControlService` invokes the installed helper with a fan index, mode, and
   optional integer RPM.
4. The helper validates the fan index and mode, reads the hardware RPM range,
   and clamps the target.
5. Manual mode is written and polled before the target is written.
6. Target and mode are read back. A mismatch restores automatic mode.
7. Only a verified result becomes active application state.

No arbitrary SMC key, file path, command, or shell fragment can be supplied
through the helper's command-line interface.

## Helper Lifecycle

The bundled helper is ad-hoc signed as part of the local build. Its installer:

- rejects non-regular or group/other-writable bundled files;
- validates the bundled code signature;
- stages a root-owned copy;
- validates the staged signature and helper version;
- moves it to the final path with mode `4755`;
- records a root-owned version marker;
- removes the legacy helper path.

An existing root-owned v4 helper at the legacy path remains usable after its
permissions and version marker are validated. This avoids an unnecessary
administrator prompt during migration while keeping the v5 update visible in
General settings.

The current implementation uses a narrowly scoped setuid helper so repeated fan
changes do not require repeated administrator prompts. A signed and notarized
XPC helper would be the preferred distribution model for a future binary
release.

## Recovery

- Normal quit requests automatic mode for active hardware-controlled fans.
- A detached helper watches the launching app process and restores automatic
  mode if that process exits.
- A failed fixed or curve write restores automatic mode before returning.
- On wake, active curve or fixed settings are reapplied and verified.

Recovery is best-effort because macOS, SMC firmware, power loss, and forced
process termination can interrupt any software path.

## Persistence

`PersistenceController` atomically writes JSON to:

```text
~/Library/Application Support/ThermoFan/state.json
```

The file stores preferences, presets, sensor visibility, staged fan settings,
and custom indexes. It contains no credentials.

## Trust Boundaries

- The SwiftUI process runs as the logged-in user.
- Administrator authorization is used only to install or update the helper.
- The installed helper is root-owned and accepts a fixed argument grammar.
- Hardware writes rely on private Apple interfaces and must be treated as
  model-specific even when key names match.
