#!/bin/bash
# Put `liddy` on PATH.
#
# Default target needs no admin password. Pass --system to install to
# /usr/local/bin instead, which is on PATH for every shell but needs root.
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET_DIR="$HOME/.local/bin"
if [[ "${1:-}" == "--system" ]]; then
  TARGET_DIR="/usr/local/bin"
fi

echo "==> building CLI"
swift build -c release --product liddy

SOURCE="$PWD/.build/release/liddy"

if [[ "$TARGET_DIR" == "/usr/local/bin" ]]; then
  sudo mkdir -p "$TARGET_DIR"
  sudo cp "$SOURCE" "$TARGET_DIR/liddy"
  sudo chmod 755 "$TARGET_DIR/liddy"
else
  mkdir -p "$TARGET_DIR"
  cp "$SOURCE" "$TARGET_DIR/liddy"
  chmod 755 "$TARGET_DIR/liddy"
fi

echo "==> installed $TARGET_DIR/liddy"
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$TARGET_DIR"; then
  echo "!! $TARGET_DIR is not on your PATH. Add this to ~/.zshrc:"
  echo "     export PATH=\"$TARGET_DIR:\$PATH\""
fi
