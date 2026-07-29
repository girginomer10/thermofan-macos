# Changelog

All notable changes to ThermoFan are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses semantic versioning while it remains pre-1.0.

## [Unreleased]

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

[Unreleased]: https://github.com/girginomer10/thermofan-macos/compare/v0.2.3...HEAD
[0.2.3]: https://github.com/girginomer10/thermofan-macos/releases/tag/v0.2.3
