#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Identifiers and the implementation revision come from ThermoFanXPC.swift so
# the bundle, launchd plist, and code signatures match what the app and daemon
# require at runtime. Exits 64 if any of them cannot be read.
# shellcheck source=scripts/packaging_contract.sh
source "$ROOT_DIR/scripts/packaging_contract.sh"
thermofan_load_packaging_contract
APP_NAME="ThermoFan"
APP_IDENTIFIER="$THERMOFAN_APP_IDENTIFIER"
HELPER_IDENTIFIER="$THERMOFAN_HELPER_IDENTIFIER"
DAEMON_PLIST_NAME="$THERMOFAN_DAEMON_PLIST_NAME"
IMPLEMENTATION_REVISION="$THERMOFAN_IMPLEMENTATION_REVISION"
BUNDLE_DIR="$ROOT_DIR/dist/$APP_NAME.app"
HELPER_BIN="$BUNDLE_DIR/Contents/MacOS/ThermoFanHelper"
DAEMON_PLIST="$BUNDLE_DIR/Contents/Library/LaunchDaemons/$DAEMON_PLIST_NAME"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$ROOT_DIR/.build/ThermoFan.iconset"
APP_VERSION="${THERMOFAN_VERSION:-0.3.0}"
BUILD_NUMBER="${THERMOFAN_BUILD_NUMBER:-$IMPLEMENTATION_REVISION}"
GIT_COMMIT="${THERMOFAN_GIT_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
SIGNING_IDENTITY="${THERMOFAN_SIGNING_IDENTITY:--}"
MINIMUM_SYSTEM_VERSION="14.0"

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "THERMOFAN_VERSION must use numeric major.minor.patch format." >&2
  exit 64
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "THERMOFAN_BUILD_NUMBER must be a positive integer." >&2
  exit 64
fi
if [[ ! "$GIT_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "THERMOFAN_GIT_COMMIT must be a full lowercase Git SHA." >&2
  exit 64
fi
if [[ "$BUILD_NUMBER" != "$IMPLEMENTATION_REVISION" ]]; then
  echo "THERMOFAN_BUILD_NUMBER must equal ThermoFanXPC.implementationRevision ($IMPLEMENTATION_REVISION)." >&2
  exit 64
fi

SIGNING_ARGUMENTS=(--force --sign "$SIGNING_IDENTITY" --options runtime)
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGNING_ARGUMENTS+=(--timestamp)
fi

cd "$ROOT_DIR"
BUILD_BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
EXECUTABLE="$BUILD_BIN_DIR/$APP_NAME"
HELPER_EXECUTABLE="$BUILD_BIN_DIR/ThermoFanHelper"
swift build -c release --arch arm64 --product "$APP_NAME"
swift build -c release --arch arm64 --product ThermoFanHelper

rm -rf "$BUNDLE_DIR"
mkdir -p \
  "$BUNDLE_DIR/Contents/MacOS" \
  "$BUNDLE_DIR/Contents/Resources" \
  "$(dirname "$DAEMON_PLIST")"
cp "$EXECUTABLE" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
cp "$HELPER_EXECUTABLE" "$HELPER_BIN"
chmod +x "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$HELPER_BIN"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Required app icon is missing: $ICON_SOURCE" >&2
  exit 1
fi
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$BUNDLE_DIR/Contents/Resources/ThermoFan.icns"
rm -rf "$ICONSET_DIR"

cat > "$BUNDLE_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>ThermoFan</string>
  <key>CFBundleIdentifier</key>
  <string>$APP_IDENTIFIER</string>
  <key>CFBundleIconFile</key>
  <string>ThermoFan</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleDisplayName</key>
  <string>ThermoFan</string>
  <key>CFBundleName</key>
  <string>ThermoFan</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>ThermoFanGitCommit</key>
  <string>$GIT_COMMIT</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MINIMUM_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright 2026 Omer Girgin. Released under the MIT License.</string>
</dict>
</plist>
PLIST

cat > "$DAEMON_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$HELPER_IDENTIFIER</string>
  <key>BundleProgram</key>
  <string>Contents/MacOS/ThermoFanHelper</string>
  <key>MachServices</key>
  <dict>
    <key>$HELPER_IDENTIFIER</key>
    <true/>
  </dict>
  <key>KeepAlive</key>
  <true/>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>$APP_IDENTIFIER</string>
  </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$BUNDLE_DIR/Contents/PkgInfo"
plutil -lint "$BUNDLE_DIR/Contents/Info.plist" "$DAEMON_PLIST" >/dev/null
if [[ "$(plutil -extract Label raw "$DAEMON_PLIST")" != "$HELPER_IDENTIFIER" \
   || "$(plutil -extract BundleProgram raw "$DAEMON_PLIST")" != "Contents/MacOS/ThermoFanHelper" \
   || "$(/usr/libexec/PlistBuddy -c "Print :MachServices:$HELPER_IDENTIFIER" "$DAEMON_PLIST")" != "true" ]]; then
  echo "LaunchDaemon plist identity or BundleProgram is invalid." >&2
  exit 1
fi
if [[ "$(stat -f '%Lp' "$HELPER_BIN")" != "755" ]]; then
  echo "ThermoFanHelper must be mode 0755 with no setuid/setgid bits." >&2
  exit 1
fi
codesign "${SIGNING_ARGUMENTS[@]}" --identifier "$HELPER_IDENTIFIER" "$HELPER_BIN" >/dev/null
codesign "${SIGNING_ARGUMENTS[@]}" --identifier "$APP_IDENTIFIER" "$BUNDLE_DIR" >/dev/null

for executable_path in "$BUNDLE_DIR/Contents/MacOS/$APP_NAME" "$HELPER_BIN"; do
  if [[ "$(lipo -archs "$executable_path")" != "arm64" ]]; then
    echo "Expected an arm64-only executable: $executable_path" >&2
    exit 1
  fi
  BUILD_INFO="$(xcrun vtool -show-build "$executable_path")"
  if [[ "$(awk '$1 == "minos" { print $2; exit }' <<<"$BUILD_INFO")" != "$MINIMUM_SYSTEM_VERSION" ]]; then
    echo "Expected macOS $MINIMUM_SYSTEM_VERSION deployment target: $executable_path" >&2
    exit 1
  fi
done

codesign --verify --strict "$HELPER_BIN"
codesign --verify --deep --strict "$BUNDLE_DIR"
echo "Built $BUNDLE_DIR ($APP_VERSION build $BUILD_NUMBER, arm64, identity: $SIGNING_IDENTITY)"
