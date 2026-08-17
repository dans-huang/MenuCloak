#!/bin/bash
# Install MenuCloak, its Raycast commands, and start the app quietly at login.
# Uninstall: launchctl bootout gui/$(id -u)/com.dans.menucloak
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
APP="/Applications/MenuCloak.app"
ditto "$(pwd)/MenuCloak.app" "$APP"
BIN="$APP/Contents/MacOS/MenuCloak"
PLIST="$HOME/Library/LaunchAgents/com.dans.menucloak.plist"
mkdir -p "$HOME/Library/LaunchAgents"
plutil -create xml1 "$PLIST"
plutil -insert Label -string com.dans.menucloak "$PLIST"
plutil -insert ProgramArguments -array "$PLIST"
plutil -insert ProgramArguments.0 -string "$BIN" "$PLIST"
plutil -insert ProgramArguments.1 -string --background "$PLIST"
plutil -insert RunAtLoad -bool true "$PLIST"
pkill -x MenuCloak 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.dans.menucloak" 2>/dev/null || true
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
  # launchd can briefly retain the previous job after bootout.
  echo "menucloak: retrying login item registration"
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi
echo "menucloak: installed app and login item"
./scripts/install-raycast-extension.sh
