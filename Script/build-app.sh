#!/bin/bash
# Assemble Liddy.app from the SwiftPM build.
#
# SwiftPM emits a bare executable; MenuBarExtra needs a real bundle with an
# Info.plist (LSUIElement=1 keeps it out of the Dock and the app switcher).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="dist/Liddy.app"

# Stamped into the bundle so Finder cannot disagree with what `liddy --version`
# prints — both come from LiddyVersion.current, which the release workflow
# rewrites from the tag. BUILD is a monotonic counter CI supplies; locally it is
# meaningless and stays 1.
VERSION="${VERSION:-$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/LiddyKit/Model/LiddyVersion.swift)}"
BUILD="${BUILD:-1}"
[[ -n "$VERSION" ]] || { echo "could not read version from Sources/LiddyKit/Model/LiddyVersion.swift" >&2; exit 1; }

echo "==> building ($CONFIG)"
swift build -c "$CONFIG" --product LiddyApp
# Bundled so the app can install the helper itself. Without this the only route to
# closed-lid mode is a Terminal, a clone of this repo, and a shell script — which is
# what the menu used to say in an error banner after letting you click a control that
# could never have worked.
swift build -c "$CONFIG" --product liddy-helper
# The CLI rides along so a downloaded .app is a complete install — otherwise the
# only route to `liddy` is a clone and a toolchain, which is not an install path
# to put in front of somebody who just downloaded a zip.
swift build -c "$CONFIG" --product liddy

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
# Built as LiddyApp so it cannot collide with the `liddy` CLI on a case-insensitive
# filesystem; it becomes plain Liddy inside the bundle.
cp ".build/$CONFIG/LiddyApp" "$APP/Contents/MacOS/Liddy"
cp ".build/$CONFIG/liddy-helper" "$APP/Contents/Helpers/liddy-helper"
cp ".build/$CONFIG/liddy" "$APP/Contents/Helpers/liddy"
# Committed, so a normal build never re-renders it — see Script/make-asset.sh.
cp "Resource/Liddy.icns" "$APP/Contents/Resources/Liddy.icns"

# Installer for the bundled helper. Runs *as root* in its entirety (the app asks for
# authorisation once, through the system prompt), so there is no `sudo` in here — and
# no `swift build` either, because an installed .app has no toolchain and no sources.
cat > "$APP/Contents/Resources/install-helper.sh" <<'INSTALLER'
#!/bin/bash
set -euo pipefail

LABEL="com.liddy.helper"
BIN="/usr/local/libexec/liddy-helper"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
OWNER_UID="${1:?usage: install-helper.sh <uid>}"
SRC="$(cd "$(dirname "$0")/.." && pwd)/Helpers/liddy-helper"

[[ -x "$SRC" ]] || { echo "bundled helper missing at $SRC" >&2; exit 1; }
[[ "$OWNER_UID" =~ ^[0-9]+$ ]] || { echo "uid must be numeric" >&2; exit 1; }

mkdir -p "$(dirname "$BIN")" /var/db/liddy
cp "$SRC" "$BIN"
chown root:wheel "$BIN"
chmod 755 "$BIN"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>--uid</string>
    <string>$OWNER_UID</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/liddy-helper.log</string>
</dict>
</plist>
PLIST

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

for _ in $(seq 1 20); do
  [[ -S /var/run/liddy-helper.sock ]] && exit 0
  sleep 0.25
done
echo "socket did not appear — check /var/log/liddy-helper.log" >&2
exit 1
INSTALLER
chmod +x "$APP/Contents/Resources/install-helper.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Liddy</string>
  <key>CFBundleDisplayName</key>       <string>Liddy</string>
  <key>CFBundleIdentifier</key>        <string>com.bygelo.liddy</string>
  <key>CFBundleExecutable</key>        <string>Liddy</string>
  <key>CFBundleIconFile</key>          <string>Liddy</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <!-- Menu-bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key>               <true/>
  <key>NSHumanReadableCopyright</key>  <string>MIT</string>
</dict>
</plist>
PLIST

# A signature gives the notification and login-item APIs a stable identity. Use a
# real one when the machine has it: an ad-hoc signature gets a fresh cdhash on
# every build, which reads as a different app each time. CI has no identity and
# falls back to ad-hoc, which is why releases tell users to clear quarantine.
SIGN="${SIGN:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n '1s/.*"\(.*\)".*/\1/p')}"
SIGN="${SIGN:--}"

# The nested helper is its own Mach-O and has to be signed before the bundle
# that contains it, or `codesign --verify --deep` rejects the result.
codesign --force --sign "$SIGN" "$APP/Contents/Helpers/liddy-helper" 2>/dev/null || echo "!! helper codesign skipped"
codesign --force --sign "$SIGN" "$APP/Contents/Helpers/liddy" 2>/dev/null || echo "!! cli codesign skipped"
codesign --force --sign "$SIGN" "$APP" 2>/dev/null || echo "!! codesign skipped"

echo "==> built $APP"
echo "    open $APP"
