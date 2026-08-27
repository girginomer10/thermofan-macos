# Architecture

ThermoFan is a SwiftUI menu bar application with an embedded, root
`SMAppService` LaunchDaemon for privileged SMC fan writes. Sensor processing,
preferences, and diagnostics stay on the local Mac.

## Components

| Area | Responsibility |
| --- | --- |
| `ThermoFanApp.swift` | App lifecycle, settings window, menu bar scene |
| `ThermalStore.swift` | Application state, refresh loop, curves, presets, recovery |
| `HardwareProbe.swift` | Hardware and temperature discovery |
| `HardwareCompatibility.swift` | Capability policy and model-independent sensor candidates |
| `SMCClient.swift` | User-process typed reads through AppleSMC |
| `FanControlService.swift` | Application-facing privileged-control facade |
| `PrivilegedFanClient.swift` | `SMAppService` lifecycle, mutually authenticated NSXPC, heartbeat lease |
| `ThermoFanXPC.swift` | Narrow protocol 9 contract and Developer ID requirements |
| `ThermoFanHelper/main.swift` | Root daemon sessions, peer policy, watchdogs, recovery |
| `ThermoFanEngine.c` | Serialized SMC writes, read-back, atomic ownership state |

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
2. The app requires the embedded LaunchDaemon to be registered, approved, and
   running from a Developer ID signed app in `/Applications`.
3. App and daemon authenticate each other over NSXPC with the exact bundle
   identifier and the same Developer ID Team ID. Debug-signed peers are denied.
4. The daemon accepts only the active local graphical console user's kernel
   supplied UID, audit session, PID, and process start identity.
5. Before a manual write is acknowledged, the daemon arms an exact-process
   exit watch and the app starts its heartbeat lease.
6. The daemon validates the protocol version, fan index, mode, RPM envelope,
   session ownership, and monotonically increasing request revision.
7. The C engine serializes the transaction, reads the hardware RPM range, and
   discovers `F{i}Md` followed by `F{i}md`. It never falls back to `FS!`.
8. Manual mode is verified before target RPM is written; mode and target are
   read back before success is reported. A mismatch starts Auto recovery.

The XPC protocol accepts only handshake, watchdog, heartbeat, bounded fan
operation, and return-all-to-Auto messages. It accepts no arbitrary SMC key,
file path, command, or shell fragment.

## Hardware Helper Lifecycle

The release bundle contains:

```text
Contents/MacOS/ThermoFanHelper
Contents/Library/LaunchDaemons/io.github.girginomer10.ThermoFan.helper.plist
```

The plist uses `BundleProgram`, exposes the same identifier as its privileged
Mach service, and is registered through `SMAppService.daemon(plistName:)`.
macOS requires administrator approval under **System Settings > General > Login
Items**. The executable remains inside the app bundle with mode `0755`; no
setuid or separately copied helper is used.

An update first tries the normal versioned handshake. Protocol 9 and later also
retain a stable, version-independent harmless recovery handshake plus
`prepareForServiceRemoval`. The former authenticates the permanent protocol-9
floor before the latter blocks writes, verifies Auto, and permits
`SMAppService` unregister/re-register. If that proof is unavailable, the old
daemon is left registered and new writes remain blocked.

On startup, protocol 9 first recovers durable ownership to Auto. It then revokes
setuid/setgid and execute bits on only four exact, verified root-owned legacy
inodes, unlinks and fsyncs them, waits for exact-path legacy processes to exit,
and performs a final Auto recovery. Manual writes use a separate readiness gate
that opens only after this whole barrier succeeds. There is no legacy
command-line or setuid fallback.

Ad-hoc builds have no Developer ID Team ID and are intentionally
monitoring-only. This keeps local development from weakening the production
peer requirements.

## Recovery

The daemon returns its durably owned fans to Auto when any of these occurs:

- explicit Return to Auto or normal app shutdown;
- XPC interruption or invalidation;
- exact client-process exit;
- missed heartbeat (2-second interval, 8-second lease timeout);
- active console user or graphical audit-session change;
- daemon `SIGTERM` or `SIGINT`;
- daemon startup with existing ownership state;
- a failed or unverified write.

Ownership is stored in a root-only state file under `/var/run` and atomically
replaced with `fsync` before a write can be accepted. It binds the claimed fan
mask to the authenticated PID and process start time, preventing PID reuse from
transferring authority. A recovery result that cannot be verified blocks new
manual writes. The daemon keeps an independent backoff recovery supervisor
active until Auto is verified; UI retries are separately bounded.

Recovery is best-effort because macOS, SMC firmware, power loss, and forced
termination can interrupt any software path.

## Persistence

`PersistenceController` atomically writes user preferences to:

```text
~/Library/Application Support/ThermoFan/state.json
```

The file stores preferences, presets, sensor visibility, staged fan settings,
and custom indexes. It contains no credentials. Privileged ownership state is
separate, root-only, and contains no account credentials.

## Trust Boundaries

- The SwiftUI process runs as the logged-in user and performs monitoring.
- launchd runs the embedded Hardware Helper as root after macOS approval.
- Both peers enforce `anchor apple generic`, the exact expected identifier,
  Developer ID certificate markers, the same Team ID, and absence of
  `get-task-allow`.
- The daemon separately requires the active local graphical console UID and a
  non-root, non-remote audit session.
- The daemon derives PID, UID, and audit-session data from NSXPC; callers do not
  submit their own identity.
- Hardware writes use private Apple interfaces and remain model-specific even
  when key names match.
