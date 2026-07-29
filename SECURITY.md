# Security Policy

ThermoFan includes a small setuid-root helper because fan writes require
privileged access to Apple's SMC interface. Security reports involving that
helper, the install flow, argument validation, code-signature checks, or
automatic-mode recovery are especially important.

## Supported Versions

| Version | Supported |
| --- | --- |
| 0.2.3 | Yes |
| Earlier versions | No |

## Reporting a Vulnerability

Please use GitHub's **Security** tab and select **Report a vulnerability**.
Do not open a public issue for an unpatched vulnerability.

Include:

- the affected ThermoFan version;
- macOS version and Mac model;
- whether the helper is installed;
- clear reproduction steps;
- impact and any suggested mitigation;
- proof-of-concept material only when needed to demonstrate the issue.

Do not include passwords, credentials, private keys, or unrelated personal
data. Reports will be handled on a best-effort basis, with fixes coordinated
before public disclosure when practical.

## Scope Notes

- The installed helper path is
  `/Library/PrivilegedHelperTools/io.github.girginomer10.ThermoFan.helper`.
- The helper only accepts version, watchdog, and bounded fan-control commands.
- Sensor diagnostics are read-only but may reveal model identifiers and current
  temperature values.
- Apple's private SMC behavior changing across macOS or hardware revisions is a
  compatibility issue unless it also creates a security or safety impact.
