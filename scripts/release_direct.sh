#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ThermoFan"
APP_PATH="$ROOT_DIR/dist/$APP_NAME.app"
SIGNING_IDENTITY="${THERMOFAN_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${THERMOFAN_NOTARY_PROFILE:-}"
APP_VERSION="${THERMOFAN_VERSION:-0.3.0}"
BUILD_NUMBER="${THERMOFAN_BUILD_NUMBER:-9}"
APP_IDENTIFIER="io.github.girginomer10.ThermoFan"
HELPER_IDENTIFIER="$APP_IDENTIFIER.helper"
DAEMON_PLIST="$APP_PATH/Contents/Library/LaunchDaemons/$HELPER_IDENTIFIER.plist"
APP_BINARY="$APP_PATH/Contents/MacOS/ThermoFan"
HELPER_PATH="$APP_PATH/Contents/MacOS/ThermoFanHelper"
GIT_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"

verify_release_checkout() {
  if [[ "$(git -C "$ROOT_DIR" branch --show-current)" != "main" ]]; then
    echo "Direct releases must be built from main." >&2
    exit 65
  fi
  if [[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" != "$GIT_SHA" ]]; then
    echo "The release HEAD changed after provenance was captured." >&2
    exit 65
  fi
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]]; then
    echo "Direct releases require a completely clean checkout." >&2
    exit 65
  fi
}

verify_release_checkout
git -C "$ROOT_DIR" fetch --quiet origin main
if [[ "$GIT_SHA" != "$(git -C "$ROOT_DIR" rev-parse origin/main)" ]]; then
  echo "The release commit must exactly match the verified origin/main SHA." >&2
  exit 65
fi

if [[ -z "$SIGNING_IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
  echo "Set THERMOFAN_SIGNING_IDENTITY and THERMOFAN_NOTARY_PROFILE first." >&2
  exit 64
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
swift test
THERMOFAN_SIGNING_IDENTITY="$SIGNING_IDENTITY" \
THERMOFAN_VERSION="$APP_VERSION" \
THERMOFAN_BUILD_NUMBER="$BUILD_NUMBER" \
THERMOFAN_GIT_COMMIT="$GIT_SHA" \
  ./scripts/build_app.sh
verify_release_checkout

if [[ -e "$APP_PATH/Contents/Library/PrivilegedHelperTools" ]]; then
  echo "Legacy PrivilegedHelperTools content is forbidden in a public release." >&2
  exit 1
fi
if [[ ! -x "$HELPER_PATH" || ! -f "$DAEMON_PLIST" ]]; then
  echo "The SMAppService LaunchDaemon payload is incomplete." >&2
  exit 1
fi
plutil -lint "$DAEMON_PLIST" >/dev/null
if [[ "$(plutil -extract Label raw "$DAEMON_PLIST")" != "$HELPER_IDENTIFIER" \
   || "$(plutil -extract BundleProgram raw "$DAEMON_PLIST")" != "Contents/MacOS/ThermoFanHelper" \
   || "$(/usr/libexec/PlistBuddy -c "Print :MachServices:$HELPER_IDENTIFIER" "$DAEMON_PLIST")" != "true" ]]; then
  echo "The LaunchDaemon plist does not expose the exact authenticated service identity." >&2
  exit 1
fi
if [[ "$(stat -f '%Lp' "$HELPER_PATH")" != "755" ]]; then
  echo "ThermoFanHelper must be 0755; setuid/setgid bits are forbidden." >&2
  exit 1
fi
if [[ "$(plutil -extract ThermoFanGitCommit raw "$APP_PATH/Contents/Info.plist")" != "$GIT_SHA" ]]; then
  echo "The signed app does not contain the exact release Git SHA." >&2
  exit 1
fi
for command_surface_path in "$APP_BINARY" "$HELPER_PATH"; do
  COMMAND_SURFACE_STRINGS="$(strings "$command_surface_path")"
  if grep -Eq -- '--fanctl|--watch|THERMOFAN_WATCHDOG_READY|osascript' <<<"$COMMAND_SURFACE_STRINGS"; then
    echo "A legacy CLI/setuid command surface was found in $command_surface_path." >&2
    exit 1
  fi
done

APP_SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$APP_PATH" 2>&1)"
TEAM_ID="$(awk -F= '$1 == "TeamIdentifier" { print $2; exit }' <<<"$APP_SIGNATURE_DETAILS")"
if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]+$ ]]; then
  echo "A real Developer ID TeamIdentifier is required." >&2
  exit 1
fi

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
  if ! grep -Eq '^Timestamp=' <<<"$SIGNATURE_DETAILS"; then
    echo "A secure signing timestamp is required: $signed_path" >&2
    exit 1
  fi
done

HELPER_SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$HELPER_PATH" 2>&1)"
HELPER_TEAM_ID="$(awk -F= '$1 == "TeamIdentifier" { print $2; exit }' <<<"$HELPER_SIGNATURE_DETAILS")"
if [[ "$HELPER_TEAM_ID" != "$TEAM_ID" ]]; then
  echo "The app and Hardware Helper must be signed by the same Team ID." >&2
  exit 1
fi

APP_REQUIREMENT="anchor apple generic and identifier \"$APP_IDENTIFIER\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM_ID\" and ! entitlement[\"com.apple.security.get-task-allow\"] exists"
HELPER_REQUIREMENT="anchor apple generic and identifier \"$HELPER_IDENTIFIER\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM_ID\" and ! entitlement[\"com.apple.security.get-task-allow\"] exists"
csreq -r="$APP_REQUIREMENT" -t >/dev/null
csreq -r="$HELPER_REQUIREMENT" -t >/dev/null
codesign --verify --strict --verbose=4 -R="$APP_REQUIREMENT" "$APP_PATH"
codesign --verify --strict --verbose=4 -R="$HELPER_REQUIREMENT" "$HELPER_PATH"

RELEASE_STAGE="$(mktemp -d /tmp/thermofan-release.XXXXXX)"
PAYLOAD_DIR="$RELEASE_STAGE/payload"
MOUNT_POINT="$RELEASE_STAGE/mount"
DMG_MOUNTED=0
cleanup() {
  if [[ "$DMG_MOUNTED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
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
preserve_notary_diagnostics() {
  local failure_suffix
  local failure_directory
  failure_suffix="$(date -u +%Y%m%dT%H%M%SZ)"
  failure_directory="$ROOT_DIR/dist/notary-failures/$APP_VERSION-${NOTARY_ID:-unknown}-$failure_suffix"
  mkdir -p "$failure_directory"
  if [[ -s "$NOTARY_SUBMISSION" ]]; then
    cp "$NOTARY_SUBMISSION" "$failure_directory/"
  fi
  if [[ -s "$NOTARY_LOG" ]]; then
    cp "$NOTARY_LOG" "$failure_directory/"
  fi
  echo "Notarization diagnostics preserved at $failure_directory" >&2
}
set +e
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json | tee "$NOTARY_SUBMISSION"
NOTARY_EXIT=${PIPESTATUS[0]}
set -e

NOTARY_STATUS="$(plutil -extract status raw "$NOTARY_SUBMISSION" 2>/dev/null || true)"
NOTARY_ID="$(plutil -extract id raw "$NOTARY_SUBMISSION" 2>/dev/null || true)"
NOTARY_LOG_EXIT=1
if [[ -n "$NOTARY_ID" ]]; then
  set +e
  xcrun notarytool log "$NOTARY_ID" "$NOTARY_LOG" --keychain-profile "$NOTARY_PROFILE"
  NOTARY_LOG_EXIT=$?
  set -e
fi
if [[ "$NOTARY_EXIT" -ne 0 || "$NOTARY_LOG_EXIT" -ne 0 || "$NOTARY_STATUS" != "Accepted" || -z "$NOTARY_ID" ]]; then
  preserve_notary_diagnostics
  echo "Notarization was not accepted (status: ${NOTARY_STATUS:-unknown})." >&2
  exit 1
fi
if ! NOTARY_ISSUE_COUNT="$(xcrun swift -e '
import Foundation
let data = FileHandle.standardInput.readDataToEndOfFile()
let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
if root["issues"] is NSNull {
    print(0)
} else if let issues = root["issues"] as? [Any] {
    print(issues.count)
} else {
    exit(2)
}
' < "$NOTARY_LOG")"; then
  preserve_notary_diagnostics
  echo "The notarization log could not be parsed for issues." >&2
  exit 1
fi
if [[ "$NOTARY_ISSUE_COUNT" != "0" ]]; then
  preserve_notary_diagnostics
  echo "The notarization log contains $NOTARY_ISSUE_COUNT issue(s); release stopped for review." >&2
  exit 1
fi

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
DMG_MOUNTED=1
MOUNTED_APP_PATH="$MOUNT_POINT/$APP_NAME.app"
MOUNTED_HELPER_PATH="$MOUNTED_APP_PATH/Contents/MacOS/ThermoFanHelper"
test -d "$MOUNTED_APP_PATH"
test -x "$MOUNTED_HELPER_PATH"
test "$(plutil -extract ThermoFanGitCommit raw "$MOUNTED_APP_PATH/Contents/Info.plist")" = "$GIT_SHA"
codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP_PATH"
codesign --verify --strict --verbose=2 "$MOUNTED_HELPER_PATH"
codesign --verify --strict --verbose=4 -R="$APP_REQUIREMENT" "$MOUNTED_APP_PATH"
codesign --verify --strict --verbose=4 -R="$HELPER_REQUIREMENT" "$MOUNTED_HELPER_PATH"
spctl --assess --type execute --verbose=4 "$MOUNTED_APP_PATH"
hdiutil detach "$MOUNT_POINT" >/dev/null
DMG_MOUNTED=0

(
  cd "$(dirname "$DMG_PATH")"
  shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256"
)
DMG_SHA256="$(awk '{print $1}' "$DMG_PATH.sha256")"
EVIDENCE_PATH="$RELEASE_STAGE/$APP_NAME-$APP_VERSION.release-evidence.plist"
plutil -create xml1 "$EVIDENCE_PATH"
plutil -insert Version -string "$APP_VERSION" "$EVIDENCE_PATH"
plutil -insert BuildNumber -string "$BUILD_NUMBER" "$EVIDENCE_PATH"
plutil -insert GitCommit -string "$GIT_SHA" "$EVIDENCE_PATH"
plutil -insert NotarySubmissionID -string "$NOTARY_ID" "$EVIDENCE_PATH"
plutil -insert NotaryStatus -string "$NOTARY_STATUS" "$EVIDENCE_PATH"
plutil -insert NotaryIssueCount -integer "$NOTARY_ISSUE_COUNT" "$EVIDENCE_PATH"
plutil -insert DMGSHA256 -string "$DMG_SHA256" "$EVIDENCE_PATH"

git -C "$ROOT_DIR" fetch --quiet origin main
verify_release_checkout
if [[ "$GIT_SHA" != "$(git -C "$ROOT_DIR" rev-parse origin/main)" ]]; then
  echo "origin/main changed while the release was being prepared; rebuild from the new verified head." >&2
  exit 65
fi

FINAL_DMG_PATH="$ROOT_DIR/dist/$DMG_BASENAME"
FINAL_CHECKSUM_PATH="$FINAL_DMG_PATH.sha256"
FINAL_NOTARY_SUBMISSION="$ROOT_DIR/dist/$(basename "$NOTARY_SUBMISSION")"
FINAL_NOTARY_LOG="$ROOT_DIR/dist/$(basename "$NOTARY_LOG")"
FINAL_EVIDENCE_PATH="$ROOT_DIR/dist/$(basename "$EVIDENCE_PATH")"
mv -f "$DMG_PATH" "$FINAL_DMG_PATH"
mv -f "$DMG_PATH.sha256" "$FINAL_CHECKSUM_PATH"
mv -f "$NOTARY_SUBMISSION" "$FINAL_NOTARY_SUBMISSION"
mv -f "$NOTARY_LOG" "$FINAL_NOTARY_LOG"
mv -f "$EVIDENCE_PATH" "$FINAL_EVIDENCE_PATH"

echo "Release artifact: $FINAL_DMG_PATH"
echo "Checksum: $FINAL_CHECKSUM_PATH"
echo "Release evidence: $FINAL_EVIDENCE_PATH"
