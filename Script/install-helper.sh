#!/bin/bash
# Install the privileged helper as a root launchd daemon.
#
# This is the only part of Liddy that needs admin rights, and it is deliberately
# the smallest surface possible: it can set `pmset disablesleep`, force sleep, and
# answer a heartbeat. It never runs a command handed to it by the app.
#
# The helper reverts `disablesleep` when the app disconnects, when heartbeats stop,
# on SIGTERM, and on its own startup — so no single crash can leave a Mac unable
# to sleep in a bag.
set -euo pipefail

cd "$(dirname "$0")/.."

LABEL="com.liddy.helper"
BIN="/usr/local/libexec/liddy-helper"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
OWNER_UID="$(id -u)"

if [[ "$OWNER_UID" == "0" ]]; then
  echo "!! run this as your normal user (it will sudo where needed), not as root" >&2
  exit 1
fi

echo "==> building helper"
swift build -c release --product liddy-helper

echo "==> installing to $BIN (needs admin)"
sudo mkdir -p "$(dirname "$BIN")" /var/db/liddy
sudo cp ".build/release/liddy-helper" "$BIN"
sudo chown root:wheel "$BIN"
sudo chmod 755 "$BIN"

echo "==> writing $PLIST"
sudo tee "$PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <!-- The helper socket is chowned to exactly this user rather than made
         world-writable, so another local account cannot toggle power settings. -->
    <string>--uid</string>
    <string>$OWNER_UID</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/liddy-helper.log</string>
</dict>
</plist>
PLIST

sudo chown root:wheel "$PLIST"
sudo chmod 644 "$PLIST"

echo "==> loading"
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST"

sleep 1
if [[ -S /var/run/liddy-helper.sock ]]; then
  echo "==> helper is up: /var/run/liddy-helper.sock"
else
  echo "!! socket missing — check /var/log/liddy-helper.log" >&2
  exit 1
fi
