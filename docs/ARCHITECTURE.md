# Architecture

ThermoFan is a SwiftUI menu bar application with a small C helper for privileged
SMC fan writes. All sensor processing and persistence stay on the local Mac.

## Components

| Area | Responsibility |
| --- | --- |
| `ThermoFanApp.swift` | App lifecycle, settings window, menu bar scene |
| `ThermalStore.swift` | Application state, refresh loop, curves, presets, recovery |
| `HardwareProbe.swift` | Hardware discovery, persistence, helper installation and invocation |
| `HardwareCompatibility.swift` | Capability policy and model-independent sensor candidates |
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
4. Already-discovered SMC sensors remain in the session topology when a key
   temporarily sleeps; its unchanged `updatedAt` marks the value as stale.
5. `ThermalStore` creates indexes from fresh contributors and keeps current
   hotspot sensors as safe fallbacks for fan curves.
6. SwiftUI observes the store and renders the menu bar and settings views.

Estimated fallback temperatures are separate, marked as estimated, and disabled
by default.

## Write Path

1. The user stages automatic, fixed, or curve mode in the UI.
2. `ThermalStore` snapshots the staged fan setting away from the main actor.
3. Before any manual write, `FanControlService` starts a privileged watchdog,
   waits for its exact readiness handshake, and retains the live process.
4. `FanControlService` invokes the installed helper with a fan index, mode, and
   optional integer RPM.
5. The helper validates the fan index and mode, reads the hardware RPM range,
   and clamps the target.
6. The helper tries `F{i}Md`, then `F{i}md`; without a verified per-fan mode
   key, the fan remains monitoring-only rather than falling back to `FS!`.
7. Manual mode is written and polled before the target is written.
8. Target and mode are read back. A mismatch restores automatic mode.
9. Only a verified result becomes active application state.

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

A root-owned v8 helper at the legacy path can be migrated after its permissions
and version marker are validated. Older v4-v7 protocols are not allowed to
write against the expanded M-series matrix and must update first.

The current implementation uses a narrowly scoped setuid helper so repeated fan
changes do not require repeated administrator prompts. Replacing it with an
embedded, authenticated `SMAppService` LaunchDaemon/XPC helper is a mandatory
gate before a public binary release; notarization alone is not a security
architecture review.

## Recovery

- Normal quit requests automatic mode for active hardware-controlled fans.
- A detached helper proves it is watching the launching app before manual
  control begins and restores only fan bits owned by that exact PID and process
  start identity if it exits.
- A failed fixed or curve write restores automatic mode before returning.
- An unverified rollback has a dedicated helper exit/result path and starts a
  bounded in-process Auto retry sequence without discarding watchdog ownership.
- On wake, stale pre-wake samples are discarded; active curve or fixed settings
  are retried within a bound, then verified back to automatic control on error.
- If a live fan loses its verified write interface, the UI leaves the active
  state and automatic recovery is retried while manual writes remain disabled.

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
