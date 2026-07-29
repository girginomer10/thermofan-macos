## Summary

Describe the problem and the change.

## Verification

- [ ] `swift test`
- [ ] `bash -n scripts/build_app.sh`
- [ ] `./scripts/build_app.sh`
- [ ] `codesign --verify --deep --strict dist/ThermoFan.app`

## Hardware Impact

- Mac model(s) tested:
- macOS version(s) tested:
- Hardware writes involved: yes / no
- Automatic-mode recovery verified: yes / no / not applicable

## Safety

- [ ] RPM remains clamped to the SMC-reported range.
- [ ] Failed writes do not remain reported as active.
- [ ] New or changed SMC mappings are supported by real hardware evidence.
