# Apple Silicon Compatibility

ThermoFan targets arm64 Macs running macOS 14 or newer. Compatibility is based
on runtime capabilities, not the marketing name of the chip.

Local ad-hoc builds can exercise monitoring and diagnostics but cannot register
the privileged fan-control daemon. Physical write/recovery acceptance therefore
requires a Developer ID signed candidate installed in `/Applications` and
approved by macOS. Any distributed candidate must separately pass the
notarization and Gatekeeper release gates.

## Runtime Policy

- `FNum = 0` is a normal fanless Mac; temperature monitoring remains available.
- Each physical fan must expose valid current, target, minimum, and maximum RPM.
- Fan mode is probed as uppercase `F{i}Md`, then lowercase `F{i}md`.
- A readable fan without either verified mode key is shown as monitoring-only.
- The legacy `FS!` mask is not used as an Apple Silicon fallback.
- Targets are clamped to the firmware range and mode/target are read back.
- Implausible/sentinel RPM values above 20,000 and inconsistent live ranges are
  rejected before a fan can become controllable.
- Unknown values, missing keys, and invalid ranges disable writes rather than
  guessing from the model identifier.
- SMC key caches are reset after wake and topology is rediscovered before any
  active setting can be reapplied.

## Evidence Levels

| Level | Meaning |
| --- | --- |
| Fixture | The firmware shape is covered by deterministic tests. |
| External hardware evidence | Another open project or physical report observed the shape. |
| ThermoFan verified | This exact ThermoFan build passed on the physical Mac. |

Only the last level justifies listing a Mac as verified by ThermoFan.

## Current Matrix

| Family | Expected topology covered in software | ThermoFan physical status |
| --- | --- | --- |
| M1 | fanless, one/two fan, uppercase mode | Pending model matrix |
| M2 | fanless, one/two fan, uppercase/legacy sensors | Pending model matrix |
| M3 | fanless, one/two fan, firmware-unlock path | Pending model matrix |
| M4 | fanless, one/two fan, uppercase mode/unlock | Mac16,11 M4 Pro read-only path observed; protocol 9 physical write/recovery acceptance and other models pending |
| M5 | fanless, one/two fan, lowercase mode | Pending model matrix |

External protocol evidence (not ThermoFan verification) is tracked from the
MIT-licensed [macos-smc-fan research and fixtures](https://github.com/agoodkind/macos-smc-fan/tree/main/docs),
the physically tested [M3 controller](https://github.com/raminsharifi/MacFanControl),
and public [M2](https://github.com/ProducerGuy/ThermalForge/issues/19) and
[M5](https://github.com/ProducerGuy/ThermalForge/issues/23) hardware reports.
Macs Fan Control's own [model list](https://crystalidea.com/macs-fan-control/supported-models)
and [release history](https://crystalidea.com/macs-fan-control/release-notes)
likewise show that compatibility is maintained as a model/firmware matrix, not
one timeless key set.

The automated fixture suite covers fanless, uppercase/lowercase mode keys,
one/two-fan layouts, read-only fallback, exact mode decoding, legacy/modern
sensor-family selection, sentinel RPM rejection, and wake cache reset. It
cannot reproduce firmware, physical RPM ramping, sleep/wake, or thermal
behavior.

## Physical Acceptance Per Model

1. Run read-only diagnostics and save model, chip, macOS build, fan count,
   ranges, selected mode key, and sensor sources.
2. Confirm Auto without writing.
3. Under observation, request a safe target above current RPM.
4. Verify manual mode and target read-back, then observe actual RPM change.
5. Return to Auto and verify both mode and physical RPM recovery.
6. Confirm XPC disconnect, app force-quit/process exit, heartbeat timeout,
   daemon restart/termination, and sleep/wake all return owned fans to Auto.
7. Repeat helper approval/update and active-user changes, including a second
   local user account where applicable.
8. Re-run after material macOS updates; private SMC behavior can change.

Submit results with the repository's hardware compatibility issue form. Until
these rows are completed, the correct product statement is “M1-M5 capability
detection with fail-closed control,” not “verified on every M-series Mac.”
The protocol 9 migration itself did not perform a physical fan write.
