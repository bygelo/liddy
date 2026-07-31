#!/bin/bash
# Assemble Liddy.app from the SwiftPM build.
#
# SwiftPM emits a bare executable; MenuBarExtra needs a real bundle with an
# Info.plist (LSUIElement=1 keeps it out of the Dock and the app switcher).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="dist/Liddy.app"

echo "==> building ($CONFIG)"
swift build -c "$CONFIG" --product LiddyApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Built as LiddyApp so it cannot collide with the `liddy` CLI on a case-insensitive
# filesystem; it becomes plain Liddy inside the bundle.
cp ".build/$CONFIG/LiddyApp" "$APP/Contents/MacOS/Liddy"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Liddy</string>
  <key>CFBundleDisplayName</key>       <string>Liddy</string>
  <key>CFBundleIdentifier</key>        <string>com.liddy.app</string>
  <key>CFBundleExecutable</key>        <string>Liddy</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <!-- Menu-bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key>               <true/>
  <key>NSHumanReadableCopyright</key>  <string>MIT</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so the notification and login-item APIs have a stable identity.
# Replace with a Developer ID signature before distributing.
codesign --force --sign - "$APP" 2>/dev/null || echo "!! codesign skipped"

echo "==> built $APP"
echo "    open $APP"
