# Agent Handoff Log

## 2026-08-01 20:59 +03 - Codex

- Task: Stabilize the first menu-bar panel opening and make fan-curve numeric
  fields editable as normal text.
- Changed: `Sources/ThermoFan/Views.swift` and `CHANGELOG.md` in commit
  `989010e`.
- Verified: `swift test` (9 tests), release app build, strict code-signature
  verification, installed-app curve field editing, and live fan read-back.
- Memory: none; behavior and root cause are documented beside the code and in
  the changelog.
- Next: no known follow-up; watch CI for commit `989010e`.

## 2026-08-04 - Codex

- Task: Filter invalid negative PMU temperature channels reported on an M2 MacBook.
- Changed: HID readings now reject the Apple Silicon `-1 C` / `-2 C` firmware sentinels; added focused policy tests.
- Verified: `swift test` (15 passed), release build, app packaging, strict code-signature check, and `git diff --check` passed.
- Memory: Negative anonymous PMU `tdev` values are invalid channels; do not relabel anonymous device numbers as specific components without model evidence.
- Next: Confirm on the affected M2 MacBook that PMU Device 4/5 disappear while valid PMU readings remain.

## 2026-08-04 - Codex

- Task: Remove cryptic `PMU Device N` labels across Apple Silicon models.
- Changed: Anonymous `tdev` channels now display as `System Temperature N`; raw product IDs remain stable for diagnostics and sensor identity.
- Verified: `swift test` (17 passed), release build, app packaging, strict code-signature check, and `git diff --check` passed.
- Memory: Apple HID `tdev` numbers are anonymous/model-dependent; use neutral names unless a model-specific mapping is hardware-verified.
- Next: Confirm the friendlier labels on the affected M2 MacBook.

## 2026-08-12 00:54 +03 - Codex

- Task: Fix ThermoFan consuming one full CPU core while its menu panel is open.
- Changed: Removed the automatic-refresh fan-icon animation that kept SwiftUI
  laying out the full panel for most of every one-second refresh cycle; updated
  the changelog.
- Verified: `swift test` (17 passed), clean release package, strict code-signature
  verification, installed-binary hash match, and live one-second-refresh testing
  with both panel and Settings open. CPU fell from about 99% to 3.2-8.2%; a
  five-second sample showed the main thread idle for 4101/4309 samples and only
  15 layout samples, versus 2868/3479 layout samples before the fix.
- Memory: Automatic telemetry must not drive long-running whole-panel animations;
  keep refresh indicators manual or isolated from the full SwiftUI hierarchy.
- Next: None for this fix. Uncommitted sensor/GPU smoothing work in
  `HardwareProbe.swift`, `SensorContinuity.swift`, and `ThermalStore.swift` was
  deliberately excluded from the build and commit.

## 2026-08-12 13:44 +03 - Codex

- Task: Fix the remaining menu-panel lag and long-running CPU/memory growth.
- Changed: Removed the duplicate SwiftUI `Settings` scene, routed every Settings
  entry through one managed window, released its hosting view/controller on
  close, and replaced the native seven-page `TabView` with a lightweight sidebar
  that builds only the selected page.
- Verified: `swift test` (17 passed), clean release package, strict signature and
  installed-binary hash checks, 10 Settings open/close cycles (window count
  returned from 1 to 0 every time), a post-close sample with no `AppKitTabView`
  or `SystemSegmentedControl` stacks, and a live first-10-seconds menu-panel test
  at 1.9-5.3% CPU.
- Memory: A closed `NSHostingController` must not stay subscribed to the live
  sensor store. On macOS 26, retaining the native Settings `TabView` caused an
  off-screen layout loop that grew to about 99% CPU, 1.3 GB physical footprint,
  and 7.2 million allocations after roughly 12 hours.
- Next: Watch long-running installed-app CPU and memory, but the retained-window
  and native-tab paths responsible for the reproduced loop are gone. Existing
  uncommitted sensor/GPU smoothing work remains excluded.

## 2026-08-12 14:55 +03 - Codex

- Task: Finish, commit, and install the pending GPU sensor and menu-temperature
  smoothing work.
- Changed: Added Apple Silicon GPU-core SMC candidates, generalized flat 40 C
  core-sentinel filtering to CPU and GPU groups, and added a bounded three-sample
  median for menu-bar/hottest-sensor selection. Added focused tests and pruned
  histories for sensors that disappear.
- Verified: `swift test` (22 passed), release packaging, strict signatures,
  installed-binary hash match, three installed-app hardware diagnostics, and a
  live menu-panel test. The four newly surfaced GPU readings changed plausibly
  across samples; panel-open CPU stayed at 3.0-8.9% after the first idle sample.
- Memory: On the Mac16,11 M4 Pro, `Tg0d`, `Tg0e`, `Tg1c`, and `Tg1d` returned
  changing plausible GPU readings; absent candidates are ignored. Uniform 40 C
  GPU-core groups should be treated as firmware sentinels without suppressing
  unrelated GPU cluster or hotspot readings.
- Next: None.

## 2026-08-27 22:33 +03 - Codex

- Task: Replace the Mac App Store plan with guarded direct distribution and
  harden runtime compatibility for M1-M5 firmware variations.
- Changed: Added capability-based `F{i}Md`/`F{i}md` and fanless/read-only
  handling; helper v8 ownership, pre-write watchdog, rollback, and `Ftst`
  safeguards; wake serialization; M-series fixtures; arm64 Developer ID,
  notarization, and isolated-DMG tooling and documentation.
- Verified: `swift test` (50 passed), strict C11 warning/syntax and release-link
  checks, arm64 release build, strict app/helper signatures, Hardened Runtime,
  macOS 14 deployment targets, helper v8, guarded-release exit 78, disabled
  one-shot fixed control, and a mounted test DMG with no nested candidate.
  Read-only M4 Pro diagnostics found 22 real sensors and one `F0Md` fan in Auto
  at a 1,000-4,900 RPM range. No fan write was performed in this session.
- Memory: Determine compatibility from live capabilities, never use `FS!` as a
  generic Apple Silicon fallback, and report physical model verification
  separately from fixture coverage. Recovery-required status needs matching
  durable owner and fan state; ownership uses PID plus process start time to
  reject PID reuse.
- Next: Replace the legacy setuid installer with authenticated
  `SMAppService`/XPC, install a Developer ID certificate and notarize, then run
  the v8 write/sleep/force-quit acceptance matrix on physical M1-M5 models.

## 2026-08-28 00:24 +03 - Codex

- Task: Complete the direct-distribution architecture and close the protocol 8
  privileged-helper risks before an M-series public release.
- Changed: Replaced the setuid/CLI helper with an embedded protocol 9
  `SMAppService` LaunchDaemon and mutually authenticated NSXPC boundary; added
  exact-process watchdog and heartbeat leases, durable fail-closed Auto
  recovery, stable update/unregister recovery, automatic legacy-helper
  retirement, registration/approval/recovery UI states, and an arm64
  Developer ID/notarized-DMG release pipeline with SHA-bound evidence. CI now
  covers arm64 macOS 14, 15, and 26, pins third-party actions by commit, and
  exposes the aggregate `Build and test` result required by branch protection;
  the macOS 14 runner explicitly selects its installed Swift 6 toolchain, and
  the shared source avoids SDK/import patterns rejected by Swift 6.0. Removed
  the last Auto-only `--fanctl` entry point and made CI fail explicitly if a
  forbidden legacy command marker remains in either release binary.
- Verified: `swift test` (52 passed after deleting two obsolete CLI-process
  classification tests), production app/helper build, strict Swift/C
  warning and analyzer checks, strict app/helper code-signature checks,
  Hardened Runtime, arm64-only binaries, macOS 14 deployment targets, mode
  `0755` with no setuid/setgid files, exact LaunchDaemon metadata, absence of
  both app/helper legacy command surfaces, and a read-only Mac16,11 M4 Pro
  diagnostic (22 sensors, one `F0Md` fan in Auto). Final adversarial reviews
  reported no remaining P0/P1/P2 findings. No root service registration or
  physical fan write was performed.
- Memory: Never accept a manual-write lease without an exact PID/start-time
  watcher; scope asynchronous replies to their connection generation; keep
  legacy migration and service removal behind independently stable Auto proof;
  release provenance must be rechecked after build and before artifact export.
- Next: Install the Developer ID Application identity and Keychain notary
  profile, produce and Gatekeeper-test the public candidate on a clean Mac, then
  complete physical write/recovery acceptance across M1-M5 models. Move the
  macOS 14 minimum-runtime gate to a physical/self-hosted runner before GitHub's
  hosted image retires on 2026-11-02.

## 2026-09-25 01:30 +03 - Claude Fable 5.1

- Task: Deep runtime wiring and reachability audit (`/deepreview`) of the
  whole app, then parallel fixes for every finding through seven subagents in
  isolated worktrees with disjoint file ownership. The user stopped the work
  before the last workstream could be reviewed and merged.
- Changed (merged to `main`, squash-merged per workstream, builds warning-free,
  60 tests pass, ad-hoc package builds and passes the `FS!`, legacy-marker, and
  source scans):
  - `7cccfb4` shared contract: `implementationRevision` 10, XPC statuses 77
    (not console user) and 78 (retiring), `HardwareHelperState`
    `.monitoringOnly`/`.wrongLocation`/`.inactiveSession`/`.unreachable`,
    `FanControlService.cachedHelperState`/`refreshHelperState()`/
    `retryAutomaticRecovery()`/`onLeaseLost`.
  - Packaging/CI/docs: `scripts/packaging_contract.sh`, source-level legacy
    marker scan, helper `FS!` check, release CI gate (`THERMOFAN_SKIP_CI_CHECK`
    bypass, `CIVerification` evidence key), `.gitignore` secrets, README
    `rm -rf` before `ditto`, COMPATIBILITY/DISTRIBUTION/SUPPORT/CONTRIBUTING
    wording, `Tests/ThermoFanTests/XPCContractTests.swift`.
  - Client (`PrivilegedFanClient.swift`, `FanControlService.swift`,
    `HardwareHelperStateTests.swift`): recovery-blocked never goes through
    removal; pure `deriveState`; cached signature checks; lease-lost callback;
    heartbeat lease generation; RPM validated before arming; 30 s readiness
    poll; manual writes refused with a legacy helper present;
    `returnAllToAutomatic(timeout:)`.
  - Hardware (`HardwareProbe.swift`, `SMCClient.swift`,
    `HIDTemperatureReader.swift`, `HardwareCompatibility.swift`,
    `CommandLineEntrypoint.swift`, `HardwareCompatibilityTests.swift`): HID
    supplement latch, HID categories, key-not-found-only cache, unknown mode
    stays nil, raw `hardwareTargetRPM`, SMC open retry, 3-sample fan-read
    debounce, sticky core family, HID re-enumeration, plausibility window,
    dead code removed, `--diagnose` extended.
  - Daemon (`Sources/ThermoFanHelper/main.swift`): 60 s retiring window
    cleared by a verified retry, 77/76 semantics, same-process takeover,
    startup order (root, launchd parent, signals, recovery, Developer ID
    check, legacy barrier), Auto revision check under a lease, durable re-check
    on removal/shutdown, 30 s legacy re-check, snapshot handshakes.
  - Views (`Views.swift`): recovery-blocked wiring and disabled controls, new
    helper states, hardware-aware status headline, raw target, draft commit
    registry, hidden-linked-sensor picker, estimated markers, Unregister
    confirmation, misc. Contains a `// MERGE-STUB` extension at the bottom
    providing no-op `retryAutomaticRecovery()`, `refreshHelperState()`, and
    `trackedCurveFanIDs` on `ThermalStore`.
  - C engine (`Helpers/ThermoFanHelper/main.c`, `ThermoFanEngine.h`): `FS!`
    compiled out on arm64, bounded exit-watch consume (returns 2 on timeout),
    lock failure escalates to 75, `Ftst` reset on every path, post-retirement
    manual-fan scan, `.installing` legacy path, `/var/run/thermofan` state
    directory with `F_FULLFSYNC`, legacy processes tracked by PID+start time.
  - Docs: ARCHITECTURE, SAFETY, SUPPORT, CHANGELOG updated to describe only
    what is merged; pending items are marked as such.
- Verified: `swift build` (zero warnings), `swift test` (60 passed),
  `./scripts/build_app.sh` (0.3.0 build 10, ad-hoc), `strings -n 3` helper
  `FS!` check, binary and source legacy-marker scans, `bash -n` on all
  scripts. Not verified: nothing was run against a registered daemon; no
  physical fan write; CI on GitHub has not yet run for these commits.
- Memory: none written; durable lessons are in the code comments and this
  entry.
- INCOMPLETE / HALF DONE (do these next, in order):
  1. `ThermalStore` workstream is NOT merged. Its agent hit an API rate limit
     before self-review. The work is preserved as WIP commit `7479044` on the
     pushed branch `worktree-agent-a3ed5e78544878a77` (worktree
     `.claude/worktrees/agent-a3ed5e78544878a77`). It builds and passes 55
     tests against base `7cccfb4` only. It touches `ThermalStore.swift`,
     `Models.swift`, `SensorContinuity.swift`, `ThermoFanApp.swift`, moves
     `PersistedState`/`PersistenceController` from `HardwareProbe.swift` into
     new `Persistence.swift`, and adds `PersistenceTests.swift`. It was meant
     to cover: main-actor use of `cachedHelperState`/`refreshHelperState()`;
     curve first-apply race (`sameConfiguration` ignoring `targetRPM`);
     applied-curve tracking with `trackedCurveFanIDs`; `onLeaseLost`
     subscription and `hardwareMode` reconciliation; placeholder fans not
     wiped; wake re-apply/reset fixes; recovery-limit observation; nil
     "Hottest sensor" tracking; estimated readings excluded from curves and
     indexes; state.json backup on decode failure and ordered quit flush;
     keyed warnings; median-based curve evaluation; preset/index edge cases;
     bounded quit and App Nap opt-out; `retryAutomaticRecovery()` and
     `refreshHelperState()` store methods; dead-code removal. REVIEW IT FIRST,
     then rebase onto `main` (expect conflicts only in `HardwareProbe.swift`
     around the deleted persistence block; the hardware branch left lines
     1-72 untouched), delete the `// MERGE-STUB` extension at the bottom of
     `Views.swift`, and re-run build/tests/package.
  2. After that merge, add on the store: a published set of fans in automatic
     recovery (views currently guess "Recovering…"), a published median-backed
     value for the hottest sensor (panel header falls back to raw), and widen
     the GPU Average index filter (about `ThermalStore.swift:941`) to include
     the hardware branch's "GPU Core N" names, then re-enable the CHANGELOG
     bullets and doc sentences that were downgraded to "pending".
  3. Until step 1 lands: the main-thread stall on each tick (P1), stale
     "Manual control active" after a daemon-ended lease (P1), silent curve
     tracking stall (P1), and placeholder wipe (P1) remain open on `main`;
     the Retry Recovery button is a no-op placeholder (the daemon supervisor
     still retries on its own, and the client no longer routes recovery
     through service removal).
  4. Daemon revision is 10: the first launch of this build against a
     registered revision-9 daemon will require the update flow
     (unregister/re-register, Login Items approval may be asked again).
  5. CI risks noted by the packaging agent: the new matrix `include`/`runner`
     expressions have not run on GitHub; the XPC encoding test was checked only
     with Swift 6.3.3, not Xcode 16.2 on macos-14; the macos-14 hosted runner
     retires 2026-11-02 (`ci.yml` `runner:` line).
  6. The six merged worktrees under `.claude/worktrees/` and their
     `worktree-agent-*` branches (all except `a3ed5e78544878a77`) are safe to
     remove with `git worktree remove` and `git branch -D`.
  7. Physical write/recovery acceptance on M1-M5 and the Developer ID /
     notarization setup from the previous entry are still open.
