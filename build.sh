#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="LookAwayLite.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O main.swift -o "$APP/Contents/MacOS/LookAwayLite"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LookAwayLite</string>
  <key>CFBundleIdentifier</key><string>local.lookawaylite</string>
  <key>CFBundleExecutable</key><string>LookAwayLite</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>LookAwayLite checks whether a meeting is in progress so it never interrupts one.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>LookAwayLite reads the active tab URL in Chrome to detect a Meet or Zoom call in progress.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "built $PWD/$APP"
