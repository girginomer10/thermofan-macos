# Changelog

All notable changes to ThermoFan are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses semantic versioning while it remains pre-1.0.

## [Unreleased]

### Added

- Runtime fan-control capability detection now supports both `F{i}Md` and the
  lowercase `F{i}md` firmware family used by newer Apple Silicon Macs.
- Deterministic M-series fixtures cover fanless, one/two-fan, uppercase,
  lowercase, monitoring-only, sensor-family, and wake-cache behavior.
- The direct-distribution build can produce an arm64 Developer ID/Hardened
  Runtime bundle, with an authenticated LaunchDaemon payload, guarded
  notarized-DMG release script, and documented public-release gates.
- Privileged writes now use protocol 9 over a narrow NSXPC interface to an
  embedded `SMAppService` LaunchDaemon. The helper remains inside
  `Contents/MacOS` and its plist inside `Contents/Library/LaunchDaemons`.
- Hardware Helper status now distinguishes registration, administrator approval
  in Login Items, update, recovery-blocked, and ready states.
- Recovery now covers heartbeat expiry, XPC loss, exact client-process exit,
  active-console-user change, daemon signals, and daemon startup.
- Protocol 9 reserves a harmless stable recovery handshake plus an
  Auto-and-unregister selector for future updates, and provides an in-app
  verified **Unregister** action.

### Changed

- Fan control now fails closed when neither per-fan mode key is verified;
  Apple's legacy `FS!` mask is no longer guessed as an Apple Silicon fallback.
- Modern and legacy Apple Silicon CPU sensor families are probed independently
  and selected from coherent live readings instead of the chip marketing name.
- Missing SMC metadata is retried after wake, and temporarily missing fans keep
  their saved configuration while hardware writes remain disabled.
- Stale pre-wake samples are discarded, wake restoration is bounded, and a lost
  write interface triggers verified automatic recovery instead of leaving an
  old curve target active.
- Fan counts and mode values now use the helper's exact decoding rules; corrupt
  or sentinel RPM ranges above 20,000 are monitoring-only.
- The app and daemon now mutually enforce the exact Developer ID identifier and
  Team ID, Developer ID certificate markers, and absence of `get-task-allow`.
  The daemon also requires the active local graphical console UID and audit
  session.
- Protocol 9 requires a verified pre-write process-exit watch and heartbeat
  lease, rejects stale request revisions, and serializes fan transactions.
- Root-owned fan ownership state is atomically replaced and binds each fan mask
  to the authenticated PID plus process start time.
- The old setuid installer and command-line write surface were removed. Startup
  recovers durable legacy ownership, revokes/removes only known safe legacy
  inodes, drains exact legacy processes, and verifies Auto again before opening
  the manual-write gate; there is no legacy fallback.
- Ad-hoc builds are monitoring-only. Runtime privileged authorization requires
  a Developer ID signed app installed in `/Applications` and approved by macOS;
  any public artifact must additionally pass notarization and Gatekeeper gates.

### Fixed

- **Retry Recovery** no longer unregisters and re-registers the Hardware
  Helper. A daemon whose protocol and revision are current but reports
  recovery required is asked to retry verified Auto directly; it is never sent
  through `prepareForServiceRemoval`, whose retiring state used to latch
  permanently and reject every later request. The fan-card and preset buttons
  can no longer follow a recovery retry with a manual write, and all manual
  controls are disabled while recovery is blocked. The Retry Recovery button
  itself still calls a placeholder until the pending `ThermalStore` work lands
  (see `docs/HANDOFF.md`).
- The service facade now caches the code-signature checks and offers a
  non-blocking helper-state snapshot plus a background refresh. Moving the
  store's per-tick status check off the main thread is pending in the unmerged
  `ThermalStore` branch.
- The client now reports every lease the daemon ended on its own (heartbeat
  expiry, XPC loss, daemon restart, console-user change, recovery after a
  failed write) through a lease-lost callback and treats status `76` as
  recovery required. The store subscription that updates fan cards is pending
  in the unmerged branch.
- Apple HID/PMU sensors no longer flicker in and out of the sensor list as the
  per-sample SMC count changes; the supplement decision is latched for the
  session. HID die and cluster channels are now categorized as CPU/GPU so they
  can serve as curve sources and fallbacks.
- The daemon now answers a background login session with a distinct
  not-console-user status, answers `76` whenever it ended the caller's lease
  itself, lets a newer connection from the same app process take over its
  lease, recovers durable ownership before its Developer ID self-check, installs
  signal handlers before the startup barrier, requires a launchd parent,
  enforces the request revision for Auto under a lease, re-verifies durable
  state on removal and shutdown, re-runs legacy cleanup if a legacy helper
  reappears, and answers handshakes from a snapshot so a long SMC transaction
  cannot make the app report it as needing an update.
- The app distinguishes monitoring-only builds, an app outside
  `/Applications`, an inactive login session, and an unresponsive helper from
  a genuine update requirement; only the last offers Update, and a handshake
  timeout no longer unregisters a daemon that was merely busy. Manual writes
  are refused app-side while a legacy privileged helper exists, an invalid RPM
  is rejected before a lease is armed, readiness is polled for up to 30 seconds
  after registration, and quit uses a bounded return-to-Auto.
- The arm64 helper no longer contains the Intel `FS!` code or string; the exit
  watch consume is bounded; a lock failure escalates to recovery required when
  a fan may be owned; recovery always resets `Ftst`; the interrupted v8
  `.installing` helper path is retired; legacy processes are tracked by PID and
  start time across retries; and ownership state moved to a root-only
  `/var/run/thermofan` directory written with `F_FULLFSYNC`.
- SMC metadata misses are cached only for key-not-found results, a failed SMC
  open is retried with a descriptive warning, a transient fan read no longer
  cancels manual control on every fan (three consecutive misses are required),
  the CPU core family and `Tp0P` meaning are fixed per session, the raw
  hardware target is shown instead of a clamped value, unknown hardware mode is
  no longer displayed as manual, HID readings use the same plausibility window
  as the SMC path, and the unused user-process SMC write path was removed.
- Number and curve fields commit their drafts before Apply and across
  Settings page switches, a hidden linked sensor stays selectable, estimated
  readings are marked in the menu bar and panel header, and Unregister asks
  for confirmation.
- Packaging identifiers and the implementation revision are read from the
  Swift contract by a shared `scripts/packaging_contract.sh`, CI scans sources
  for legacy command markers (short Swift literals were invisible to the
  binary `strings` check), the arm64 helper is required to contain no `FS!`
  string, direct releases require a successful CI run for the released commit,
  and `XPCContractTests` pins the eight selectors, their reply encodings, and
  every status constant.
- The root daemon now arms its exact-process watchdog before the first manual
  write; one-shot fixed/curve CLI writes are unavailable.
- A rollback that cannot be verified is no longer collapsed into a generic
  error; it starts an independent backoff Auto-recovery supervisor.
- An Auto failure for a fan ThermoFan does not own no longer claims that a
  watchdog is available; recovery-required status now needs matching durable
  process ownership and the exact fan bit.
- Durable fan ownership now records the app process start time as well as its
  PID, so PID reuse cannot transfer recovery authority to an unrelated process.
- App and helper binaries now both carry a real macOS 14 deployment target,
  independently verified in the build script and CI.
- Direct-release DMG staging now keeps candidate artifacts outside the mounted
  payload, preventing a partial nested copy of the DMG from entering itself.
- The direct-release script now rejects setuid bits, legacy helper payloads and
  CLI markers, Team ID mismatches, debug entitlements, and non-exact app/helper
  requirements before notarization.
- Direct releases now require a clean `origin/main` SHA before and after the
  build, passing tests, a build number tied to the helper revision, zero
  notary-log issues, post-staple mounted-payload verification, and a SHA-bound
  evidence plist. CI covers arm64 macOS 14, 15, and 26.
- The macOS 14 Swift 6.0 build no longer imports the SDK's mutable
  `mach_task_self_` global directly or relies on newer actor/function-reference
  inference accepted only by later Swift 6 toolchains.

- Menu-bar temperatures now use a short median window so a single transient SMC
  spike does not flash as the current hottest reading.
- Uniform 40 C GPU-core firmware sentinels are hidden while changing GPU-core
  readings remain visible.
- Closing Settings now releases its SwiftUI tab hierarchy instead of letting a
  hidden window continue laying itself out on every sensor refresh, which could
  eventually consume a full CPU core and make the menu panel slow to open.
- Settings now builds only the selected page through a lightweight sidebar,
  avoiding the native tab layout cycle and the initial cost of measuring every
  settings page at once.
- Automatic sensor refreshes no longer animate the menu-panel fan icon and
  continuously drive SwiftUI layout work when the panel is open at a short
  refresh interval.
- Apple Silicon performance-core rows that all report the known 40 C SMC
  sentinel are now hidden instead of appearing as live per-core temperatures.
- The menu bar panel no longer dismisses itself when the first hardware sample
  changes the status-item readout just as the panel opens.
- Curve temperature and RPM fields can now be cleared, replaced, and corrected
  before validation, including comma-decimal temperature input.
- Committing a curve value with Return no longer writes the same value again
  when the field later loses focus.

## [0.2.5] - 2026-07-29

### Fixed

- Performance-core rows no longer disappear when Apple Silicon SMC keys return
  temporary sleep or sentinel values.
- Retained values are visibly labeled as last readings instead of being
  presented as current measurements.
- Thermal indexes ignore stale contributors when a fresh source is available,
  and curve control falls back to a current system hotspot instead of following
  an old per-core reading.

## [0.2.4] - 2026-07-29

### Fixed

- Existing root-owned v4 helpers remain usable after strict permission and
  version validation, so the public helper-identity migration does not block fan
  control behind another administrator prompt.
- The optional Helper update still installs v5 and removes the legacy path.

## [0.2.3] - 2026-07-29

### Added

- Real SMC and Apple PMU/HID temperature discovery.
- Real fan discovery with current, target, minimum, and maximum RPM.
- Automatic, fixed-RPM, and sensor-linked curve modes.
- Editable curve graph, numeric point fields, and labeled axes.
- Built-in CPU, GPU, and system hotspot indexes.
- User-defined hottest-value and average indexes.
- Presets, sensor visibility controls, menu bar selections, and launch at login.
- Read-only `--diagnose` hardware report.
- One-time privileged helper with crash watchdog support.

### Changed

- Hardware writes now verify both manual mode and target RPM through SMC
  read-back before the UI reports success.
- Failed writes return the affected fan to automatic control.
- The helper installer now verifies the staged binary and uses the permanent
  `io.github.girginomer10.ThermoFan.helper` identity.
- Curve points are normalized to safe monotonic temperature and RPM values.

### Fixed

- Apple Silicon mode writes that are acknowledged asynchronously are polled and
  retried before a target write.
- Curve control no longer fails on the first mode transition on the validated
  M4 Pro system.
- Helper updates no longer require an administrator password for every fan
  change.

[Unreleased]: https://github.com/girginomer10/thermofan-macos/compare/v0.2.5...HEAD
[0.2.5]: https://github.com/girginomer10/thermofan-macos/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/girginomer10/thermofan-macos/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/girginomer10/thermofan-macos/releases/tag/v0.2.3
