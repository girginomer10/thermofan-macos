# Safety

ThermoFan can change physical fan behavior. Use fixed and curve modes only when
you understand the tradeoffs and can observe the machine during initial tests.

## Built-in Guardrails

- Fans are discovered from the SMC; no synthetic controllable fan is created.
- RPM targets are clamped to the minimum and maximum reported by the SMC.
- Manual mode is confirmed before a target is written.
- The target and mode are read back before success is reported.
- A failed write attempts to restore automatic control.
- Normal quit and a detached watchdog attempt to restore automatic control.
- Curve temperatures and RPM values are normalized into monotonic order.
- Automatic mode remains the default.

## Limits

- Apple's SMC interface is private and undocumented.
- A familiar SMC key can behave differently on another model or macOS release.
- Target read-back confirms the requested value, not immediate physical RPM.
- A watchdog and quit handler are best-effort, not a firmware-level guarantee.
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
