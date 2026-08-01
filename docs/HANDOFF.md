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
