#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP=MenuCloak.app
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
GOOGLE_CLIENT_ID="${MENUCLOAK_GOOGLE_CLIENT_ID:-}"
if [ -n "$GOOGLE_CLIENT_ID" ]; then
  plutil -replace MenuCloakGoogleClientID -string "$GOOGLE_CLIENT_ID" "$APP/Contents/Info.plist"
fi
BUNDLED_GOOGLE_CLIENT_ID="$(plutil -extract MenuCloakGoogleClientID raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$BUNDLED_GOOGLE_CLIENT_ID" != *.apps.googleusercontent.com ]]; then
  echo "error: MenuCloakGoogleClientID is missing or invalid" >&2
  exit 1
fi
cp assets/MenuCloak.icns "$APP/Contents/Resources/MenuCloak.icns"
cp assets/MenuCloakMenuTemplate.png "$APP/Contents/Resources/MenuCloakMenuTemplate.png"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/MenuCloak"
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP"
