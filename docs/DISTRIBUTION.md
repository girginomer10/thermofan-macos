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
7. The released commit is the verified `origin/main` head and has a completed,
   successful CI push run (enforced by `release_direct.sh`).

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

The app identifier, helper identifier, and plist name are defined once, as
`appIdentifier`, `helperIdentifier`, and `daemonPlistName` in
`Sources/FanControlXPC/ThermoFanXPC.swift`. `scripts/packaging_contract.sh`
reads them from there for `build_app.sh`, `release_direct.sh`, and CI, and
stops with exit status 64 if any of them is missing or malformed.

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
repository. The build number defaults to `ThermoFanXPC.implementationRevision`
(currently 10) and must equal it, so a launchd payload change cannot ship
without forcing a helper update. Any other value stops the build with exit
status 64:

```sh
THERMOFAN_VERSION=0.3.0 \
THERMOFAN_BUILD_NUMBER=10 \
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
identity and Keychain notarization profile. Before building, it requires a
clean `main` checkout that matches `origin/main`. It also requires a completed,
successful push run of the `CI` workflow for that exact commit, checked with
`gh run list --commit <sha> --workflow CI --event push`. If `gh` is missing,
the query fails, or no such run exists, it exits with status 78.
`THERMOFAN_SKIP_CI_CHECK=1` bypasses only this CI check: the script prints a
loud warning and the release evidence records `CIVerification` as skipped.

The script then scans `Sources/` and `Helpers/` for the legacy command surface,
runs the full tests, and embeds that Git SHA. It verifies the embedded
LaunchDaemon layout. It forbids setuid bits, the old CLI surface in both
executables, and the `FS!` key string in the arm64 helper. It checks both exact
code requirements and creates and signs the DMG. Notarization must return
`Accepted` with zero logged issues. The script staples and re-verifies the
artifact, mounts the finished DMG read-only to recheck its app and helper
payload, and runs Gatekeeper checks. Finally, it writes a SHA-256 checksum and
a release-evidence plist. Rejected submissions keep their submission and log
JSON under the ignored `dist/notary-failures` directory for diagnosis.

```sh
THERMOFAN_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
THERMOFAN_NOTARY_PROFILE=thermofan-notary \
./scripts/release_direct.sh
```

## What CI Verifies

CI (`.github/workflows/ci.yml`) runs on GitHub-hosted arm64 macOS 14, macOS 15,
and macOS 26 runners and only ever uses an ad-hoc signature. On each runner it:

- runs `swift test`, including the `XPCContractTests` wire-contract pins;
- checks the identifiers and implementation revision against literal values;
- scans the sources for the legacy command surface;
- builds the bundle with `scripts/build_app.sh`;
- checks the result's structure: ad-hoc signature validity, the Hardened
  Runtime flag, signing identifiers, Info.plist and LaunchDaemon plist
  contents, arm64-only executables, the macOS 14 deployment target, file
  modes, and banned strings in both executables, including `FS!` in the helper.

CI cannot run Developer ID signing, designated-requirement verification
(`codesign -R` against a real Team ID; CI only syntax-checks the requirement
strings with `csreq`), notarization, stapling, or Gatekeeper (`spctl`)
assessment. It has no Developer ID identity, Team ID, or notary credentials.
Those checks run only in `scripts/release_direct.sh` on a machine that has the
credentials. A green CI run is required for a release, but it is not enough on
its own.

### macOS 14 Runner Retirement

GitHub's hosted arm64 `macos-14` image is scheduled to retire on 2 November
2026 (see GitHub's
[runner announcement](https://github.com/actions/runner-images/issues/13518)).
The macOS 14 leg is the minimum-OS gate. Before that date, move it to a
self-hosted or physical macOS 14 Apple Silicon runner. Do not delete the leg or
replace it with a check on a newer OS only. Do not set
`continue-on-error: true` either, because a failed leg could then pass the
aggregate `Build and test` check.

The line to change is `runner:` in the `include` entry for `os: macos-14` in
`.github/workflows/ci.yml`:

```yaml
            runner: macos-14
```

Change it to the custom label you assign to the self-hosted runner, for
example:

```yaml
            runner: thermofan-macos-14-arm64
```

Keep `os: macos-14` so the job name and the Xcode selection step stay the
same. The runner needs Xcode 16.2 at `/Applications/Xcode_16.2.app` and
passwordless `sudo xcode-select`; otherwise, adjust that step. This is a public
repository, so set fork pull request workflows to require approval for all
outside contributors (**Settings > Actions > General**) and review each run
before approving it. Unreviewed code must never run on the self-hosted machine.

## Secrets

Never commit `.p12`, `.p8`, passwords, private keys, App Store Connect keys, or
notarization credentials. As a safety net, `.gitignore` excludes `*.p12`,
`*.p8`, `*.mobileprovision`, `*.notary-profile`, `.env`, and `.env.*`. That
does not make it safe to store secrets in the checkout, so keep them in
Keychain or outside the repository.
