#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP=MenuCloak.app
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
GOOGLE_CLIENT_ID="${MENUCLOAK_GOOGLE_CLIENT_ID:-}"
if [ -n "$GOOGLE_CLIENT_ID" ]; then
  plutil -insert MenuCloakGoogleClientID -string "$GOOGLE_CLIENT_ID" "$APP/Contents/Info.plist"
fi
cp assets/MenuCloak.icns "$APP/Contents/Resources/MenuCloak.icns"
cp assets/MenuCloakMenuTemplate.png "$APP/Contents/Resources/MenuCloakMenuTemplate.png"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/MenuCloak"
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP"
