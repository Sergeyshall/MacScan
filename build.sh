#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) MacScan.app into ./build.
#   ./build.sh            build only
#   ./build.sh --install  build and copy to /Applications
#   ./build.sh --zip      build and create build/MacScan.zip for sharing
# VERSION=1.2 BUILD_NUMBER=7 ./build.sh   sets the app version (the release workflow does this)
set -euo pipefail
cd "${0:A:h}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MacScan"

APP="build/MacScan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacScan"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacScan</string>
  <key>CFBundleDisplayName</key><string>MacScan</string>
  <key>CFBundleIdentifier</key><string>app.macscan</string>
  <key>CFBundleExecutable</key><string>MacScan</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>MacScan uses AppleScript to run fixes that need your administrator password, and to move apps to the Trash.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $PWD/$APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/MacScan"))"

case "${1:-}" in
  --install)
    rm -rf /Applications/MacScan.app
    cp -R "$APP" /Applications/
    echo "Installed: /Applications/MacScan.app" ;;
  --zip)
    rm -f build/MacScan.zip
    ditto -c -k --keepParent "$APP" build/MacScan.zip
    echo "Zipped: $PWD/build/MacScan.zip" ;;
esac
