# Direct Distribution

ThermoFan is distributed directly and is not a Mac App Store product. It uses
private SMC access and a root LaunchDaemon, which do not fit the App Store
sandbox/review model. Public binaries must use Apple Developer ID signing,
notarization, and Gatekeeper validation.

## Current Release Status

The protocol 9 `SMAppService`/NSXPC architecture is implemented: the helper is
embedded, mutually authenticated, mode `0755`, and has no setuid or legacy CLI
fallback. A public 0.3.0 binary is still blocked in this environment because:

- no usable `Developer ID Application` identity and Team ID are available;
- notarization, stapling, and clean quarantined-copy Gatekeeper acceptance have
  therefore not been completed; and
- physical write/recovery acceptance remains pending across the M1-M5 matrix.

No public binary should be described as released until every remaining gate is
independently verified. No physical fan write was performed as part of this
migration.

## Release Gates

1. App and helper are signed with the same valid `Developer ID Application`
   identity, Hardened Runtime, and a secure timestamp.
2. Apple notarization returns `Accepted`; the ticket is stapled and validated.
3. The notarization log contains no issues; post-staple signature and DMG
   integrity checks pass, and release evidence binds the artifact to Git SHA.
4. Gatekeeper accepts a freshly downloaded, quarantined DMG and installed app
   on a clean Mac.
5. The installed app runs from the canonical `/Applications/ThermoFan.app`,
   `SMAppService` registration is
   approved under **System Settings > General > Login Items**, and the exact
   mutual XPC requirements pass.
6. Relevant physical M-series rows in `COMPATIBILITY.md` pass, including Auto,
   manual read-back, physical RPM response, recovery, sleep/wake, and force-quit.

Notarization checks signing and malicious content. It does not certify private
SMC behavior or prove compatibility with a Mac model.

## Embedded Service Layout

The signed app contains both the daemon executable and registration plist:

```text
ThermoFan.app/Contents/MacOS/ThermoFanHelper
ThermoFan.app/Contents/Library/LaunchDaemons/io.github.girginomer10.ThermoFan.helper.plist
```

The plist uses `BundleProgram=Contents/MacOS/ThermoFanHelper`, advertises the
`io.github.girginomer10.ThermoFan.helper` Mach service, and is registered with
`SMAppService.daemon(plistName:)`. It is not copied to
`/Library/PrivilegedHelperTools`.

## Mutual Developer ID Requirements

The app accepts only the helper identifier; the helper accepts only the app
identifier. Both pin the runtime Team ID, Developer ID Application certificate
markers, and reject `get-task-allow`:

```text
anchor apple generic
and identifier "io.github.girginomer10.ThermoFan"
and certificate 1[field.1.2.840.113635.100.6.2.6] exists
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
and certificate leaf[subject.OU] = "TEAM_ID"
and ! entitlement["com.apple.security.get-task-allow"] exists
```

```text
anchor apple generic
and identifier "io.github.girginomer10.ThermoFan.helper"
and certificate 1[field.1.2.840.113635.100.6.2.6] exists
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
and certificate leaf[subject.OU] = "TEAM_ID"
and ! entitlement["com.apple.security.get-task-allow"] exists
```

The daemon also requires the XPC peer's kernel-supplied UID to match the active
console user and its audit session to be local, graphical, non-root, and
non-remote.

## Legacy Security Migration and Removal

The release app detects the four known earlier helpers under
`/Library/PrivilegedHelperTools`, shows a persistent security warning, and
immediately starts the macOS-approved service migration. Manual writes remain
blocked until the new daemon revokes executable privilege on the exact safe
inodes, unlinks them, drains already-running exact-path processes, and completes
a final verified Auto recovery.

Protocol 9 permanently reserves a harmless stable recovery handshake and
`prepareForServiceRemoval`. Updates and the in-app **Unregister** action use
them over the mutually authenticated connection, independent of the normal
versioned handshake. macOS must then report `.notRegistered`;
`.requiresApproval` and `.notFound` fail closed.

## Local Build

`./scripts/build_app.sh` creates an arm64, macOS 14+, Hardened Runtime bundle.
Its default ad-hoc signature has no Team ID, so the app remains
monitoring-only; this is intentional and cannot be overridden by a development
flag.

```sh
./scripts/build_app.sh
codesign --verify --deep --strict dist/ThermoFan.app
```

Version, build number, and signing identity can be supplied without editing the
repository:

```sh
THERMOFAN_VERSION=0.3.0 \
THERMOFAN_BUILD_NUMBER=9 \
THERMOFAN_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
./scripts/build_app.sh
```

## Apple Credentials

Create a `Developer ID Application` certificate through the Apple Developer
account and install its private key in the login keychain. Store notarization
credentials in Keychain rather than source files or shell history:

```sh
xcrun notarytool store-credentials thermofan-notary
```

Apple references:

- [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Notarize macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)

## Release Candidate Script

`scripts/release_direct.sh` requires an available Developer ID Application
identity and Keychain notarization profile. It verifies the embedded
LaunchDaemon layout, forbids setuid bits and the old CLI surface, checks both
exact code requirements, requires a clean `main` checkout matching
`origin/main`, runs the full tests, embeds that Git SHA, creates and signs the
DMG, requires notarization `Accepted` with zero logged issues, staples and
re-verifies the artifact, mounts the finished DMG read-only and rechecks its app
and helper payload, runs Gatekeeper checks, and writes a SHA-256 checksum plus
release-evidence plist. Rejected submissions preserve their submission and log
JSON under the ignored `dist/notary-failures` directory for diagnosis. CI runs
the same build/test/package checks on arm64 macOS 14, macOS 15, and macOS 26
runners.

GitHub's hosted arm64 `macos-14` image is scheduled to retire on 2 November
2026. Before that date, preserve the minimum-OS gate on a physical or
self-hosted macOS 14 Apple Silicon runner; do not silently replace it with a
newer-OS-only build check. See GitHub's
[runner announcement](https://github.com/actions/runner-images/issues/13518).

```sh
THERMOFAN_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
THERMOFAN_NOTARY_PROFILE=thermofan-notary \
./scripts/release_direct.sh
```

Never commit `.p12`, `.p8`, passwords, private keys, App Store Connect keys, or
notarization credentials.
