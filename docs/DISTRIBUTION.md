# Direct Distribution

ThermoFan targets direct distribution outside the Mac App Store. The current
build's private SMC access and separately installed privileged helper do not fit
the Mac App Store sandbox/review model, while direct distribution can use
Apple's Developer ID and notarization flow.

## Release Gates

A public binary is ready only after all of these are true:

1. The current setuid helper has been replaced by an embedded, authenticated
   `SMAppService` LaunchDaemon/XPC helper.
2. The app and every nested executable are signed with a valid
   `Developer ID Application` identity, Hardened Runtime, and a secure
   timestamp.
3. Apple notarization returns `Accepted`; the ticket is stapled and validated.
4. Gatekeeper accepts a freshly downloaded, quarantined copy on a clean Mac.
5. The relevant physical M-series hardware rows in `COMPATIBILITY.md` pass.

Notarization checks signing and malicious content. It does not certify private
SMC behavior or prove compatibility with a Mac model.

## Local Build

`./scripts/build_app.sh` creates an arm64, Hardened Runtime bundle with an ad-hoc
signature. This is for development and does not establish a trusted publisher:

```sh
./scripts/build_app.sh
codesign --verify --deep --strict dist/ThermoFan.app
```

Version, build number, and signing identity can be supplied without editing the
repository:

```sh
THERMOFAN_VERSION=0.2.6 \
THERMOFAN_BUILD_NUMBER=8 \
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

`scripts/release_direct.sh` builds a signed arm64 app, creates a signed DMG,
submits it with `notarytool`, requires an explicit `Accepted` result, downloads
Apple's notarization log, staples the ticket, runs Gatekeeper checks, and writes
a portable SHA-256 checksum. It deliberately refuses a normal public release
until the helper migration is complete.

The temporary legacy-helper override exists only for a restricted pre-release
candidate and must not be presented as the public release gate:

```sh
THERMOFAN_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
THERMOFAN_NOTARY_PROFILE=thermofan-notary \
THERMOFAN_ALLOW_LEGACY_SETUID_RELEASE=YES \
./scripts/release_direct.sh
```

Never commit `.p12`, `.p8`, passwords, private keys, App Store Connect keys, or
notarization credentials.
