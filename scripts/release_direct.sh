#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ThermoFan"
APP_PATH="$ROOT_DIR/dist/$APP_NAME.app"
SIGNING_IDENTITY="${THERMOFAN_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${THERMOFAN_NOTARY_PROFILE:-}"
APP_VERSION="${THERMOFAN_VERSION:-0.2.6}"
BUILD_NUMBER="${THERMOFAN_BUILD_NUMBER:-8}"

if [[ -z "$SIGNING_IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
  echo "Set THERMOFAN_SIGNING_IDENTITY and THERMOFAN_NOTARY_PROFILE first." >&2
  exit 64
fi
if [[ "${THERMOFAN_ALLOW_LEGACY_SETUID_RELEASE:-}" != "YES" ]]; then
  cat >&2 <<'MESSAGE'
Public release is intentionally blocked while ThermoFan still installs a
setuid helper. Finish the SMAppService/XPC helper migration first. For a
restricted pre-release candidate only, set
THERMOFAN_ALLOW_LEGACY_SETUID_RELEASE=YES after reviewing docs/DISTRIBUTION.md.
MESSAGE
  exit 78
fi
if [[ "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
  echo "THERMOFAN_SIGNING_IDENTITY must be a Developer ID Application identity." >&2
  exit 64
fi
AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning)"
if ! grep -Fq "\"$SIGNING_IDENTITY\"" <<<"$AVAILABLE_IDENTITIES"; then
  echo "The requested Developer ID signing identity is not available in Keychain." >&2
  exit 69
fi

cd "$ROOT_DIR"
THERMOFAN_SIGNING_IDENTITY="$SIGNING_IDENTITY" \
THERMOFAN_VERSION="$APP_VERSION" \
THERMOFAN_BUILD_NUMBER="$BUILD_NUMBER" \
  ./scripts/build_app.sh

HELPER_PATH="$APP_PATH/Contents/Library/PrivilegedHelperTools/ThermoFanHelper"
for signed_path in "$HELPER_PATH" "$APP_PATH"; do
  codesign --verify --deep --strict --verbose=2 "$signed_path"
  SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$signed_path" 2>&1)"
  if ! grep -Eq '^CodeDirectory .* flags=.*\(.*runtime.*\)' <<<"$SIGNATURE_DETAILS"; then
    echo "Hardened Runtime is required: $signed_path" >&2
    exit 1
  fi
  if ! grep -Fq 'Authority=Developer ID Application:' <<<"$SIGNATURE_DETAILS"; then
    echo "A Developer ID Application signature is required: $signed_path" >&2
    exit 1
  fi
  if ! grep -Eq '^TeamIdentifier=[A-Z0-9]+$' <<<"$SIGNATURE_DETAILS"; then
    echo "A real TeamIdentifier is required: $signed_path" >&2
    exit 1
  fi
done

RELEASE_STAGE="$(mktemp -d /tmp/thermofan-release.XXXXXX)"
PAYLOAD_DIR="$RELEASE_STAGE/payload"
cleanup() {
  rm -rf "$RELEASE_STAGE"
}
trap cleanup EXIT

mkdir -p "$PAYLOAD_DIR"
ditto "$APP_PATH" "$PAYLOAD_DIR/$APP_NAME.app"
ln -s /Applications "$PAYLOAD_DIR/Applications"

DMG_BASENAME="$APP_NAME-$APP_VERSION.dmg"
DMG_PATH="$RELEASE_STAGE/$DMG_BASENAME"
hdiutil create \
  -volname "$APP_NAME $APP_VERSION" \
  -srcfolder "$PAYLOAD_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"

NOTARY_SUBMISSION="$RELEASE_STAGE/$APP_NAME-$APP_VERSION.notary-submission.json"
NOTARY_LOG="$RELEASE_STAGE/$APP_NAME-$APP_VERSION.notary-log.json"
set +e
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json | tee "$NOTARY_SUBMISSION"
NOTARY_EXIT=${PIPESTATUS[0]}
set -e

NOTARY_STATUS="$(plutil -extract status raw "$NOTARY_SUBMISSION" 2>/dev/null || true)"
NOTARY_ID="$(plutil -extract id raw "$NOTARY_SUBMISSION" 2>/dev/null || true)"
if [[ -n "$NOTARY_ID" ]]; then
  xcrun notarytool log "$NOTARY_ID" "$NOTARY_LOG" --keychain-profile "$NOTARY_PROFILE"
fi
if [[ "$NOTARY_EXIT" -ne 0 || "$NOTARY_STATUS" != "Accepted" || -z "$NOTARY_ID" ]]; then
  echo "Notarization was not accepted (status: ${NOTARY_STATUS:-unknown})." >&2
  exit 1
fi

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
(
  cd "$(dirname "$DMG_PATH")"
  shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256"
)

FINAL_DMG_PATH="$ROOT_DIR/dist/$DMG_BASENAME"
FINAL_CHECKSUM_PATH="$FINAL_DMG_PATH.sha256"
FINAL_NOTARY_SUBMISSION="$ROOT_DIR/dist/$(basename "$NOTARY_SUBMISSION")"
FINAL_NOTARY_LOG="$ROOT_DIR/dist/$(basename "$NOTARY_LOG")"
mv -f "$DMG_PATH" "$FINAL_DMG_PATH"
mv -f "$DMG_PATH.sha256" "$FINAL_CHECKSUM_PATH"
mv -f "$NOTARY_SUBMISSION" "$FINAL_NOTARY_SUBMISSION"
mv -f "$NOTARY_LOG" "$FINAL_NOTARY_LOG"

echo "Release artifact: $FINAL_DMG_PATH"
echo "Checksum: $FINAL_CHECKSUM_PATH"
