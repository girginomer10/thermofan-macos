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
