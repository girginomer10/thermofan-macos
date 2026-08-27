# Safety

ThermoFan can change physical fan behavior. Use fixed and curve modes only when
you understand the tradeoffs and can observe the machine during initial tests.

## Built-in Guardrails

- Fans are discovered from the SMC; no synthetic controllable fan is created.
- RPM targets are clamped to the minimum and maximum reported by the SMC.
- Sentinel or inconsistent RPM ranges (including values above 20,000 RPM) are
  rejected before hardware control is enabled.
- Manual mode is confirmed before a target is written.
- Uppercase/lowercase mode keys are discovered at runtime; an unknown control
  surface remains monitoring-only.
- The legacy `FS!` force mask is not guessed as an Apple Silicon fallback.
- The target and mode are read back before success is reported.
- A failed write attempts to restore automatic control.
- If that rollback cannot be verified, the helper returns a distinct recovery
  result; the app performs at most three verified Auto retries while the
  pre-started watchdog remains alive.
- A privileged watchdog must prove it is observing the app before the first
  manual write; normal quit and the watchdog restore automatic control.
- Root-owned recovery state binds each claimed fan to both the app PID and its
  process start time, so PID reuse cannot transfer watchdog authority.
- Sleep/wake sampling is serialized, stale pre-wake results are discarded, and
  a lost control interface triggers verified automatic recovery with retries.
- Curve temperatures and RPM values are normalized into monotonic order.
- Automatic mode remains the default.

## Limits

- Apple's SMC interface is private and undocumented.
- A familiar SMC key can behave differently on another model or macOS release.
- Target read-back confirms the requested value, not immediate physical RPM.
- The verified watchdog and quit handler are still software recovery paths, not
  a firmware-level guarantee.
- Apple firmware mode value `3` means system control, not manual control.
- Fixed RPM can be too low for a workload even when it is inside the hardware
  range.
- ThermoFan cannot prevent hardware faults, firmware behavior, power loss, or
  another privileged tool from changing the same fan.

## Safer Testing

1. Close other fan-control applications.
2. Keep the Fans pane visible.
3. Start with a target above the current automatic RPM.
4. Apply the setting and confirm both **Hardware: Manual** and the target.
5. Watch actual RPM and temperatures for several minutes.
6. Select **Return to Auto** and verify **Hardware: Auto**.
7. Stop immediately if temperatures rise unexpectedly, the actual fan does not
   respond, or macOS becomes unstable.

Do not use early tests on an unattended Mac or during critical work.

## Emergency Return to Automatic Control

Use **Return to Auto** in the Fans pane. If the UI is unavailable, quit
ThermoFan so the watchdog can attempt recovery. Rebooting normally returns SMC
fan policy to firmware control, but behavior remains model-dependent.

When reporting a safety issue, include the Mac model, chip, macOS version,
ThermoFan version, fan range, requested target, observed target, observed
current RPM, and whether automatic mode was restored.
