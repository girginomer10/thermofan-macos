#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ThermoFan"
BUNDLE_DIR="$ROOT_DIR/dist/$APP_NAME.app"
HELPER_SRC="$ROOT_DIR/Helpers/ThermoFanHelper/main.c"
HELPER_POLICY_SRC="$ROOT_DIR/Sources/FanSafetyPolicy/ThermoFanSafetyPolicy.c"
HELPER_POLICY_INCLUDE="$ROOT_DIR/Sources/FanSafetyPolicy/include"
HELPER_BIN="$BUNDLE_DIR/Contents/Library/PrivilegedHelperTools/ThermoFanHelper"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$ROOT_DIR/.build/ThermoFan.iconset"
APP_VERSION="${THERMOFAN_VERSION:-0.2.6}"
BUILD_NUMBER="${THERMOFAN_BUILD_NUMBER:-8}"
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

SIGNING_ARGUMENTS=(--force --sign "$SIGNING_IDENTITY" --options runtime)
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGNING_ARGUMENTS+=(--timestamp)
fi

cd "$ROOT_DIR"
BUILD_BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
EXECUTABLE="$BUILD_BIN_DIR/$APP_NAME"
swift build -c release --arch arm64

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources" "$(dirname "$HELPER_BIN")"
cp "$EXECUTABLE" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
/usr/bin/clang -arch arm64 -mmacosx-version-min="$MINIMUM_SYSTEM_VERSION" \
  -std=c11 -Wall -Wextra -Wpedantic -Werror -O2 \
  -I "$HELPER_POLICY_INCLUDE" "$HELPER_SRC" "$HELPER_POLICY_SRC" \
  -framework IOKit -framework CoreFoundation -lproc -o "$HELPER_BIN"
chmod +x "$HELPER_BIN"
codesign "${SIGNING_ARGUMENTS[@]}" --identifier io.github.girginomer10.ThermoFan.helper "$HELPER_BIN" >/dev/null

if [[ -f "$ICON_SOURCE" ]]; then
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
fi

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
  <string>io.github.girginomer10.ThermoFan</string>
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

printf 'APPL????' > "$BUNDLE_DIR/Contents/PkgInfo"
codesign "${SIGNING_ARGUMENTS[@]}" --identifier io.github.girginomer10.ThermoFan "$BUNDLE_DIR" >/dev/null

for executable_path in "$BUNDLE_DIR/Contents/MacOS/$APP_NAME" "$HELPER_BIN"; do
  if [[ "$(lipo -archs "$executable_path")" != "arm64" ]]; then
    echo "Expected an arm64-only executable: $executable_path" >&2
    exit 1
  fi
  if [[ "$(xcrun vtool -show-build "$executable_path" | awk '$1 == "minos" { print $2; exit }')" != "$MINIMUM_SYSTEM_VERSION" ]]; then
    echo "Expected macOS $MINIMUM_SYSTEM_VERSION deployment target: $executable_path" >&2
    exit 1
  fi
done

codesign --verify --strict "$HELPER_BIN"
codesign --verify --deep --strict "$BUNDLE_DIR"
echo "Built $BUNDLE_DIR ($APP_VERSION build $BUILD_NUMBER, arm64, identity: $SIGNING_IDENTITY)"
