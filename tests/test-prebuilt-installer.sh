#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

TEST_ROOT="$(mktemp -d)"
cleanup() {
  /usr/bin/trash "$TEST_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

if ./scripts/package-release.sh '../escape' >/dev/null 2>&1; then
  echo "release packaging accepted an unsafe version path" >&2
  exit 1
fi

SOURCE_APP="$TEST_ROOT/source/MenuCloak.app"
MENUCLOAK_GOOGLE_CLIENT_ID="test.apps.googleusercontent.com" \
MENUCLOAK_GOOGLE_CLIENT_SECRET="ci-test-secret" \
MENUCLOAK_BUILD_OUTPUT="$SOURCE_APP" \
  ./build.sh >/dev/null

INFO_PLIST="$SOURCE_APP/Contents/Info.plist"
BEFORE_HASH="$(shasum -a 256 "$INFO_PLIST" | awk '{print $1}')"
MENUCLOAK_SOURCE_APP="$SOURCE_APP" \
MENUCLOAK_RAYCAST_MODE=skip \
MENUCLOAK_INSTALL_DRY_RUN=1 \
  ./install-launchagent.sh --prebuilt >/dev/null
AFTER_HASH="$(shasum -a 256 "$INFO_PLIST" | awk '{print $1}')"

if [[ "$BEFORE_HASH" != "$AFTER_HASH" ]]; then
  echo "prebuilt installer rebuilt or modified the release app" >&2
  exit 1
fi
plutil -extract MenuCloakGoogleClientSecret raw -o - "$INFO_PLIST" >/dev/null

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
printf '%s\n' \
  '#!/bin/bash' \
  'printf "launchctl %s\n" "$*" >> "$MENUCLOAK_TEST_LOG"' \
  > "$FAKE_BIN/launchctl"
printf '%s\n' \
  '#!/bin/bash' \
  'printf "pkill %s\n" "$*" >> "$MENUCLOAK_TEST_LOG"' \
  > "$FAKE_BIN/pkill"
chmod +x "$FAKE_BIN/launchctl" "$FAKE_BIN/pkill"

APPLICATIONS_DIR="$TEST_ROOT/Applications"
LAUNCH_AGENTS_DIR="$TEST_ROOT/LaunchAgents"
INSTALL_LOG="$TEST_ROOT/install.log"
PATH="$FAKE_BIN:$PATH" \
MENUCLOAK_TEST_LOG="$INSTALL_LOG" \
MENUCLOAK_SOURCE_APP="$SOURCE_APP" \
MENUCLOAK_APPLICATIONS_DIR="$APPLICATIONS_DIR" \
MENUCLOAK_LAUNCH_AGENTS_DIR="$LAUNCH_AGENTS_DIR" \
MENUCLOAK_RAYCAST_MODE=skip \
  ./install-launchagent.sh --prebuilt >/dev/null

INSTALLED_APP="$APPLICATIONS_DIR/MenuCloak.app"
INSTALLED_PLIST="$LAUNCH_AGENTS_DIR/com.dans.menucloak.plist"
[[ -x "$INSTALLED_APP/Contents/MacOS/MenuCloak" ]]
plutil -extract MenuCloakGoogleClientSecret raw -o - \
  "$INSTALLED_APP/Contents/Info.plist" >/dev/null
[[ "$(plutil -extract ProgramArguments.0 raw -o - "$INSTALLED_PLIST")" == \
  "$INSTALLED_APP/Contents/MacOS/MenuCloak" ]]
grep 'launchctl bootstrap' "$INSTALL_LOG" >/dev/null
grep 'pkill -x MenuCloak' "$INSTALL_LOG" >/dev/null

SOURCE_BUILD_APP="$TEST_ROOT/source-build/MenuCloak.app"
MENUCLOAK_GOOGLE_CLIENT_ID="test.apps.googleusercontent.com" \
MENUCLOAK_GOOGLE_CLIENT_SECRET="ci-test-secret" \
MENUCLOAK_BUILD_OUTPUT="$SOURCE_BUILD_APP" \
MENUCLOAK_SOURCE_APP="$SOURCE_BUILD_APP" \
MENUCLOAK_RAYCAST_MODE=skip \
MENUCLOAK_INSTALL_DRY_RUN=1 \
  ./install-launchagent.sh >/dev/null
plutil -extract MenuCloakGoogleClientSecret raw -o - \
  "$SOURCE_BUILD_APP/Contents/Info.plist" >/dev/null

echo "prebuilt installer preserves OAuth and completes an isolated install"
