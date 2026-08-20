#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${MENUCLOAK_BUILD_OUTPUT:-MenuCloak.app}"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
GOOGLE_OAUTH_CLIENT_JSON="${MENUCLOAK_GOOGLE_OAUTH_CLIENT_JSON:-}"
if [ -n "$GOOGLE_OAUTH_CLIENT_JSON" ]; then
  if [ ! -f "$GOOGLE_OAUTH_CLIENT_JSON" ]; then
    echo "error: OAuth client JSON not found" >&2
    exit 1
  fi
  GOOGLE_CLIENT_ID="$(plutil -extract installed.client_id raw -o - "$GOOGLE_OAUTH_CLIENT_JSON" 2>/dev/null || true)"
  GOOGLE_CLIENT_SECRET="$(plutil -extract installed.client_secret raw -o - "$GOOGLE_OAUTH_CLIENT_JSON" 2>/dev/null || true)"
  if [[ "$GOOGLE_CLIENT_ID" != *.apps.googleusercontent.com ]] || [ -z "$GOOGLE_CLIENT_SECRET" ]; then
    echo "error: OAuth client JSON must contain an installed Desktop client ID and secret" >&2
    exit 1
  fi
else
  GOOGLE_CLIENT_ID="${MENUCLOAK_GOOGLE_CLIENT_ID:-}"
  GOOGLE_CLIENT_SECRET="${MENUCLOAK_GOOGLE_CLIENT_SECRET:-}"
fi
if [ -n "$GOOGLE_CLIENT_ID" ]; then
  plutil -replace MenuCloakGoogleClientID -string "$GOOGLE_CLIENT_ID" "$APP/Contents/Info.plist"
fi
if [ -n "$GOOGLE_CLIENT_SECRET" ]; then
  plutil -insert MenuCloakGoogleClientSecret -string "$GOOGLE_CLIENT_SECRET" "$APP/Contents/Info.plist" 2>/dev/null ||
    plutil -replace MenuCloakGoogleClientSecret -string "$GOOGLE_CLIENT_SECRET" "$APP/Contents/Info.plist"
fi
BUNDLED_GOOGLE_CLIENT_ID="$(plutil -extract MenuCloakGoogleClientID raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$BUNDLED_GOOGLE_CLIENT_ID" != *.apps.googleusercontent.com ]]; then
  echo "error: MenuCloakGoogleClientID is missing or invalid" >&2
  exit 1
fi
cp assets/MenuCloak.icns "$APP/Contents/Resources/MenuCloak.icns"
cp assets/MenuCloakMenuTemplate.png "$APP/Contents/Resources/MenuCloakMenuTemplate.png"
BUILD_DIR="$(mktemp -d)"
cleanup() {
  /usr/bin/trash "$BUILD_DIR" 2>/dev/null || true
}
trap cleanup EXIT
swiftc -O -swift-version 5 -target arm64-apple-macosx11.0 main.swift \
  -o "$BUILD_DIR/MenuCloak-arm64"
swiftc -O -swift-version 5 -target x86_64-apple-macosx11.0 main.swift \
  -o "$BUILD_DIR/MenuCloak-x86_64"
lipo -create "$BUILD_DIR/MenuCloak-arm64" "$BUILD_DIR/MenuCloak-x86_64" \
  -output "$APP/Contents/MacOS/MenuCloak"
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP"
