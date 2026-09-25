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
- The arm64 helper contains no `FS!` force-mask code path; a fan without a
  verified per-fan mode key stays monitoring-only.
- The target and mode are read back before success is reported.
- A failed write attempts to restore automatic control.
- If that rollback cannot be verified, the daemon returns a distinct recovery
  result, blocks new manual writes, and keeps a backoff Auto-recovery supervisor
  active until hardware recovery is verified.
- The mutually authenticated daemon must synchronously arm an exact-process
  exit watch before the first manual write. A 2-second app heartbeat has an
  8-second lease timeout.
- XPC loss, process exit, heartbeat expiry, active-console-user change, daemon
  `SIGTERM`/`SIGINT`, and daemon startup all trigger Auto recovery.
- Root-owned recovery state lives in `/var/run/thermofan` (mode `0700`), is
  written atomically with `F_FULLFSYNC`, and binds each claimed fan to both the
  authenticated app PID and its process start time, so PID reuse cannot
  transfer watchdog authority.
- Only the active local graphical console user's UID and audit session may hold
  a fan-control lease.
- App and daemon mutually require the exact Developer ID identifier and Team
  ID; ad-hoc builds are monitoring-only.
- The helper is an embedded `SMAppService` LaunchDaemon with mode `0755`; no
  setuid or legacy command-line fallback can perform a write.
- Earlier exact helper inodes are deprivileged and removed, their running
  processes are drained by PID and start time, and Auto is checked again
  before manual writes open. When a legacy executable was removed, every fan
  whose mode key reads manual is also returned to Auto.
- A lease the daemon ends on its own (heartbeat expiry, connection loss,
  console-user change, recovery) is reported to the app's service layer; the
  fan-card reconciliation is pending in the unmerged `ThermalStore` branch.
- While recovery is blocked, every manual control is disabled. The Retry
  Recovery action is wired to a store method that is still a placeholder until
  that branch lands; the daemon's own recovery supervisor keeps retrying.
- Sleep/wake sampling is serialized, stale pre-wake results are discarded, and
  a lost control interface triggers verified automatic recovery with retries.
- Curve temperatures and RPM values are normalized into monotonic order.
- Automatic mode remains the default.

## Limits

- Apple's SMC interface is private and undocumented.
- A familiar SMC key can behave differently on another model or macOS release.
- Target read-back confirms the value after clamping to the hardware range,
  not the requested value and not immediate physical RPM. The Fans pane shows
  the raw hardware target register for comparison.
- The watchdog, heartbeat, connection, signal, and startup handlers are still
  software recovery paths, not a firmware-level guarantee.
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

Use **Return to Auto** in the Fans pane. If the helper reports **Recovery
blocked**, Return to Auto is hidden and the daemon's own supervisor retries
Auto; **Retry Recovery** is currently a placeholder (see `docs/HANDOFF.md`).
If the UI is unavailable, quit ThermoFan; connection loss, process exit, or
heartbeat expiry tells the root daemon to attempt recovery. Rebooting normally returns SMC fan policy to
firmware control, but behavior remains model-dependent.

When reporting a safety issue, include the Mac model, chip, macOS version,
ThermoFan version, fan range, requested target, observed target, observed
current RPM, and whether automatic mode was restored.
