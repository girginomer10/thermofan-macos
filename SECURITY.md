# Security Policy

ThermoFan's unreleased 0.3.0 candidate performs privileged fan writes through
an embedded `SMAppService` LaunchDaemon and a narrow NSXPC protocol. Reports
involving peer authentication, session authorization, bounded SMC commands,
durable ownership, or automatic recovery are especially important.

## Supported Versions

| Version | Supported |
| --- | --- |
| Unreleased 0.3.0 candidate (`main`) | Pre-release security review only |
| Published 0.2.5 and earlier | No |

No published ThermoFan binary is currently supported for privileged fan
control. Public 0.3.0 support begins only after the Developer ID, notarization,
Gatekeeper, and physical acceptance gates in `docs/DISTRIBUTION.md` pass.

## Reporting a Vulnerability

Use GitHub's **Security** tab and select **Report a vulnerability**. Do not open
a public issue for an unpatched vulnerability.

Include:

- the affected ThermoFan version and protocol version;
- macOS version and Mac model;
- Hardware Helper registration/approval state;
- clear reproduction steps and impact;
- proof-of-concept material only when needed.

Do not include passwords, credentials, private keys, or unrelated personal
data. Reports are handled on a best-effort basis, with fixes coordinated before
public disclosure when practical.

## Privileged Boundary

- The helper executable is embedded at
  `ThermoFan.app/Contents/MacOS/ThermoFanHelper` with mode `0755`.
- Its `SMAppService` plist is embedded under
  `Contents/Library/LaunchDaemons/io.github.girginomer10.ThermoFan.helper.plist`.
- macOS launchd runs it as root only after administrator approval under
  **System Settings > General > Login Items**.
- There is no setuid executable, separately installed helper, legacy CLI write
  surface, arbitrary command execution, or development-signature bypass.
- Ad-hoc builds have no Developer ID Team ID and remain monitoring-only.

The app requires the helper identifier
`io.github.girginomer10.ThermoFan.helper`; the daemon requires the app
identifier `io.github.girginomer10.ThermoFan`. Each NSXPC peer must satisfy
`anchor apple generic`, its exact identifier, the Developer ID Application
certificate markers, the same runtime Team ID, and absence of
`com.apple.security.get-task-allow`.

The daemon additionally derives PID, UID, and audit-session identity from the
NSXPC connection. It accepts only the active local graphical console user; root,
remote, non-graphical, loginwindow, setup-user, and inactive-user sessions are
denied.

## Recovery Boundary

- Manual writes require a pre-armed exact PID plus process-start-time watchdog.
- A heartbeat lease, XPC loss, process exit, console-user change, `SIGTERM`,
  `SIGINT`, and daemon startup all feed verified Auto recovery.
- Fan ownership is stored in root-only atomic state under `/var/run`; malformed
  or unsafe paths fail closed.
- A recovery result that cannot be verified blocks new manual writes.
- After initial startup recovery, only four exact safe root-owned legacy
  helper/version inodes have execution privilege revoked and are removed. The
  daemon drains exact-path legacy processes and performs a final Auto recovery
  before its separate manual-write gate opens.
- Protocol 9 permanently retains a harmless stable recovery handshake followed
  by an authenticated Auto-and-unregister selector for safe future updates and
  in-app removal.

Sensor diagnostics are read-only but may reveal model identifiers, SMC keys,
and current temperatures. A private Apple SMC behavior change is a compatibility
issue unless it also creates a security or safety impact.
