#!/bin/bash
# Build a Google-enabled app and package it with the one-pass app + Raycast installer.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Info.plist)"
if [[ -n "${1:-}" ]]; then
  RELEASE_VERSION="$1"
elif [[ "$APP_VERSION" == *.*.* ]]; then
  RELEASE_VERSION="$APP_VERSION"
else
  RELEASE_VERSION="${APP_VERSION}.0"
fi
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: release version must use numeric X.Y.Z format" >&2
  exit 2
fi
OUTPUT_DIR="${MENUCLOAK_RELEASE_OUTPUT_DIR:-$HOME/.config/menucloak/releases}"
ARCHIVE_NAME="MenuCloak-${RELEASE_VERSION}.zip"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"

if [[ -e "$ARCHIVE_PATH" ]]; then
  echo "error: release archive already exists: $ARCHIVE_PATH" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
cleanup() {
  /usr/bin/trash "$STAGING_DIR" 2>/dev/null || true
}
trap cleanup EXIT

BUILT_APP="$STAGING_DIR/MenuCloak.app"
MENUCLOAK_BUILD_OUTPUT="$BUILT_APP" ./build.sh
"$BUILT_APP/Contents/MacOS/MenuCloak" --selftest
codesign --verify --deep --strict "$BUILT_APP"
if ! plutil -extract MenuCloakGoogleClientSecret raw -o - \
  "$BUILT_APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "error: release build is missing its Google OAuth client secret" >&2
  exit 1
fi

RAYCAST_BUILD_HOME="$STAGING_DIR/raycast-home"
mkdir -p "$RAYCAST_BUILD_HOME"
(
  export HOME="$RAYCAST_BUILD_HOME"
  cd raycast-extension
  npm ci
  npm run lint
  npm run build
)
BUILT_RAYCAST="$RAYCAST_BUILD_HOME/.config/raycast/extensions/menucloak"
if [[ ! -f "$BUILT_RAYCAST/package.json" ]]; then
  echo "error: Raycast build did not produce an installable extension" >&2
  exit 1
fi
for command in set-focus toggle turn-on turn-off open-settings; do
  if [[ ! -f "$BUILT_RAYCAST/$command.js" ]]; then
    echo "error: Raycast build is missing $command.js" >&2
    exit 1
  fi
done

PACKAGE_DIR="$STAGING_DIR/MenuCloak-${RELEASE_VERSION}"
mkdir -p "$PACKAGE_DIR/scripts"
ditto "$BUILT_APP" "$PACKAGE_DIR/MenuCloak.app"
ditto "$BUILT_RAYCAST" "$PACKAGE_DIR/raycast-extension-built"
cp install-launchagent.sh "$PACKAGE_DIR/install-launchagent.sh"
cp scripts/install-raycast-extension.sh "$PACKAGE_DIR/scripts/install-raycast-extension.sh"
mkdir -p "$PACKAGE_DIR/raycast-extension"
while IFS= read -r tracked_file; do
  relative_path="${tracked_file#raycast-extension/}"
  mkdir -p "$PACKAGE_DIR/raycast-extension/$(dirname "$relative_path")"
  cp "$tracked_file" "$PACKAGE_DIR/raycast-extension/$relative_path"
done < <(git ls-files raycast-extension)
cp README.md LICENSE "$PACKAGE_DIR/"

printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'ROOT="$(cd "$(dirname "$0")" && pwd)"' \
  '"$ROOT/install-launchagent.sh" --prebuilt' \
  'echo' \
  'echo "MenuCloak installation finished. You can close this window."' \
  > "$PACKAGE_DIR/Install MenuCloak.command"
chmod +x "$PACKAGE_DIR/Install MenuCloak.command" \
  "$PACKAGE_DIR/install-launchagent.sh" \
  "$PACKAGE_DIR/scripts/install-raycast-extension.sh"

MENUCLOAK_INSTALL_DRY_RUN=1 "$PACKAGE_DIR/install-launchagent.sh" --prebuilt

mkdir -p "$OUTPUT_DIR"
ditto -c -k --norsrc --keepParent "$PACKAGE_DIR" "$ARCHIVE_PATH"
if unzip -Z1 "$ARCHIVE_PATH" | grep '/node_modules/' >/dev/null; then
  echo "error: release archive contains local Raycast dependencies" >&2
  exit 1
fi
if ! unzip -Z1 "$ARCHIVE_PATH" | grep '/raycast-extension-built/set-focus.js$' >/dev/null; then
  echo "error: release archive is missing the installable Raycast extension" >&2
  exit 1
fi
if ! unzip -Z1 "$ARCHIVE_PATH" | grep '/Install MenuCloak.command$' >/dev/null; then
  echo "error: release archive is missing the one-pass installer" >&2
  exit 1
fi
echo "packaged $ARCHIVE_PATH"
