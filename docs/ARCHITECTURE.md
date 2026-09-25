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
3. Apple PMU/HID temperatures supplement SMC readings. The decision to show
   the non-storage HID channels is latched for the session once it is made, so
   the sensor list cannot flicker as the per-sample SMC count varies. HID die
   and cluster channels carry CPU/GPU categories so they qualify as curve
   sources.
4. Already-discovered SMC sensors remain in the session topology when a key
   temporarily sleeps; its unchanged `updatedAt` marks the value as stale.
   Only the SMC key-not-found result is cached; other transient SMC errors are
   retried on the next sample. Retaining HID sensors the same way is part of
   the pending `ThermalStore` work (see `docs/HANDOFF.md`).
5. `ThermalStore` creates indexes from fresh contributors. The curve-tracking
   fixes (tracking with the applied curve while edits are staged, hotspot
   fallback without replacing the user's choice, return to Auto when no fresh
   source exists) are pending in the unmerged `ThermalStore` branch.
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
   session ownership, and monotonically increasing request revision for every
   manual write and for an Auto request under an active lease. An Auto request
   without a lease is accepted in the safe direction and reported as not
   ThermoFan-owned rather than as a verified write.
7. The C engine serializes the transaction, reads the hardware RPM range, and
   discovers `F{i}Md` followed by `F{i}md`. The arm64 helper contains no `FS!`
   code path at all; a fan with neither per-fan mode key stays
   monitoring-only.
8. The target is clamped to the hardware range, manual mode is verified before
   it is written, and mode and target are read back before success is
   reported. The read-back confirms the clamped value; the app shows the raw
   hardware target register separately. A mismatch starts Auto recovery.

The XPC protocol accepts exactly eight messages: `handshake`, `armWatchdog`,
`heartbeat`, `applyFan`, `returnAllFansToAutomatic`, `retryAutomaticRecovery`,
`recoveryHandshake`, and `prepareForServiceRemoval`. It accepts no arbitrary
SMC key, file path, command, or shell fragment. Reply statuses are `0`
success, `1` failure, `75` recovery required, `76` lease lost, `77` not the
active console user, and `78` retiring after a verified Auto.

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

An update first tries the normal versioned handshake. A registered daemon whose
protocol and implementation revision are current is never sent through the
removal path: a recovery-required answer (`75`) routes to
`retryAutomaticRecovery`, a handshake timeout leaves the daemon registered and
reports it as not responding, and only a genuine version mismatch or a
retiring daemon (`78`) proceeds. Protocol 9 and later also retain a stable,
version-independent harmless recovery handshake plus
`prepareForServiceRemoval`. The former authenticates the permanent protocol-9
floor before the latter blocks writes, verifies Auto, and permits
`SMAppService` unregister/re-register. After `prepareForServiceRemoval`
verifies Auto the daemon refuses writes for up to 60 seconds or until it is
unregistered; a successful recovery retry ends that window early. If the proof
is unavailable, the old daemon is left registered and new writes remain
blocked.

On startup the daemon checks that it runs as root under launchd, installs its
signal handlers, recovers durable ownership to Auto, and only then performs
its Developer ID self-check (exit 78 on failure, so a mis-signed helper still
recovers before it exits). It then revokes setuid/setgid and execute bits on
only five exact, verified root-owned legacy inodes (including the interrupted
v8 `.installing` copy), unlinks and fsyncs them, waits for the exact legacy
processes recorded by PID and start time to exit, and performs a final Auto
recovery. When a legacy executable was actually removed, that recovery also
returns every fan whose per-fan mode key reads manual to Auto, because
pre-protocol-9 helpers kept no usable record. Manual writes use a separate
readiness gate that opens only after this whole barrier succeeds, and the
daemon re-runs the barrier if a legacy path reappears while it is idle. There
is no legacy command-line or setuid fallback.

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
- a newer connection from the same app process taking over its lease;
- a failed or unverified write.

Whenever the daemon itself ended a lease, the affected connection's next
request answers `76` so the app drops its armed state. The service facade
reports every lost lease through an `onLeaseLost` callback; the `ThermalStore`
subscription that reconciles fan cards is pending in the unmerged branch, so
the UI can still show a stale manual state until then.

Ownership is stored in a root-only state file under `/var/run/thermofan`
(mode `0700`) and atomically replaced with `F_FULLFSYNC` before a write can be
accepted. Records that earlier helpers left directly in `/var/run` are
recovered to Auto and removed. The state binds the claimed fan mask to the
authenticated PID and process start time, preventing PID reuse from
transferring authority. A recovery result that cannot be verified blocks new
manual writes. The daemon keeps an independent backoff recovery supervisor
active until Auto is verified; UI retries are separately bounded.

The service facade offers a non-blocking cached helper-state snapshot and a
background refresh, and caches the code-signature checks. `ThermalStore` still
refreshes helper status synchronously on each tick from the main actor;
switching it to the cached snapshot is pending in the unmerged branch, so a
long apply, recovery, or registration can still stall the menu panel.

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
