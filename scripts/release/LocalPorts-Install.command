#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIR/LocalPorts.app"
TARGET_APP="/Applications/LocalPorts.app"

print_step() {
  echo
  echo "==> $1"
}

fail() {
  echo
  echo "Install failed: $1"
  exit 1
}

if [[ ! -d "$SOURCE_APP" ]]; then
  fail "LocalPorts.app was not found next to this installer. Put this file in the same folder as LocalPorts.app and run again."
fi

print_step "Closing running LocalPorts process (if any)"
osascript -e 'tell application "LocalPorts" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -x "LocalPorts" >/dev/null 2>&1 || true

print_step "Installing LocalPorts.app to /Applications"
if ! ditto "$SOURCE_APP" "$TARGET_APP" >/dev/null 2>&1; then
  echo "Administrator permission is required to copy into /Applications."
  sudo ditto "$SOURCE_APP" "$TARGET_APP"
fi

print_step "Removing macOS quarantine attribute"
if xattr -p com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1; then
  if ! xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1; then
    echo "Administrator permission is required to update app attributes."
    sudo xattr -dr com.apple.quarantine "$TARGET_APP"
  fi
fi

print_step "Opening LocalPorts"
open "$TARGET_APP" || fail "Could not open $TARGET_APP"

echo
echo "LocalPorts installation completed."
echo "If Start on Login still fails, open LocalPorts Settings > Startup Options > Open Login Items Settings."
