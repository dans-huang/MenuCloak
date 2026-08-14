#!/bin/bash
# Install MenuCloak in /Applications and start it quietly at login.
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
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $PLIST"
