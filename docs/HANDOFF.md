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
