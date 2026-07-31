#!/bin/bash
# Remove the helper and make certain `disablesleep` is left off.
set -euo pipefail

LABEL="com.liddy.helper"

echo "==> unloading (the helper reverts disablesleep on SIGTERM)"
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true

# Belt and braces: assert the setting is off regardless of how the helper exited.
sudo pmset -a disablesleep 0 || true

sudo rm -f "/Library/LaunchDaemons/$LABEL.plist" /usr/local/libexec/liddy-helper
sudo rm -rf /var/db/liddy
sudo rm -f /var/run/liddy-helper.sock

echo "==> removed. Current setting:"
pmset -g | grep -i disablesleep || echo "    disablesleep not set (normal sleep restored)"
