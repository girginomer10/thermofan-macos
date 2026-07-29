#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ThermoFan"
BUNDLE_DIR="$ROOT_DIR/dist/$APP_NAME.app"
EXECUTABLE="$ROOT_DIR/.build/release/$APP_NAME"
HELPER_SRC="$ROOT_DIR/Helpers/ThermoFanHelper/main.c"
HELPER_BIN="$BUNDLE_DIR/Contents/Library/PrivilegedHelperTools/ThermoFanHelper"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$ROOT_DIR/.build/ThermoFan.iconset"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources" "$(dirname "$HELPER_BIN")"
cp "$EXECUTABLE" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
/usr/bin/clang -Wall -Wextra -Wpedantic -O2 "$HELPER_SRC" -framework IOKit -framework CoreFoundation -o "$HELPER_BIN"
chmod +x "$HELPER_BIN"
codesign --force --sign - "$HELPER_BIN" >/dev/null

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

cat > "$BUNDLE_DIR/Contents/Info.plist" <<'PLIST'
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
  <string>0.2.5</string>
  <key>CFBundleVersion</key>
  <string>7</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
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
codesign --force --deep --sign - "$BUNDLE_DIR" >/dev/null
echo "Built $BUNDLE_DIR"
