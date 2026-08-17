#!/bin/bash
# Install MenuCloak's companion Raycast commands from the Store when available,
# or build the copy shipped in this repository while Store review is pending.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTENSION_DIR="$PROJECT_DIR/raycast-extension"
STORE_URL="${MENUCLOAK_RAYCAST_STORE_URL:-https://www.raycast.com/dans_huang/menucloak}"
MODE="${MENUCLOAK_RAYCAST_MODE:-auto}"
RAYCAST_APP=""

for candidate in "/Applications/Raycast.app" "$HOME/Applications/Raycast.app"; do
  if [[ -d "$candidate" ]]; then
    RAYCAST_APP="$candidate"
    break
  fi
done

if [[ -z "$RAYCAST_APP" ]]; then
  echo "raycast: not installed; skipped companion commands"
  exit 0
fi

case "$MODE" in
  auto|store|local|skip) ;;
  *)
    echo "raycast: MENUCLOAK_RAYCAST_MODE must be auto, store, local, or skip" >&2
    exit 2
    ;;
esac

if [[ "$MODE" == "skip" ]]; then
  echo "raycast: skipped by MENUCLOAK_RAYCAST_MODE=skip"
  exit 0
fi

store_is_available() {
  local status
  status="$(curl --location --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 3 --max-time 8 "$STORE_URL" 2>/dev/null || true)"
  [[ "$status" == "200" ]]
}

install_from_store() {
  open "$STORE_URL"
  echo "raycast: opened the official MenuCloak Store page"
  echo "raycast: confirm Install once in Raycast to finish"
}

install_from_repo() {
  if [[ ! -f "$EXTENSION_DIR/package-lock.json" ]]; then
    echo "raycast: bundled extension is missing from $EXTENSION_DIR" >&2
    exit 1
  fi
  if ! command -v npm >/dev/null 2>&1; then
    echo "raycast: Store listing is not live yet and npm is unavailable" >&2
    echo "raycast: install Node.js, then run this installer again" >&2
    exit 1
  fi

  (
    cd "$EXTENSION_DIR"
    npm ci
    npm run lint
    npm run build
  )

  local installed_manifest="$HOME/.config/raycast/extensions/menucloak/package.json"
  if [[ ! -f "$installed_manifest" ]]; then
    echo "raycast: build finished but the installed extension could not be verified" >&2
    exit 1
  fi

  local command_count
  command_count="$(/usr/bin/plutil -extract commands raw -o - "$installed_manifest" 2>/dev/null || true)"
  if [[ "$command_count" -ne 5 ]]; then
    echo "raycast: expected 5 MenuCloak commands, found $command_count" >&2
    exit 1
  fi

  open "$RAYCAST_APP"
  echo "raycast: installed and verified 5 MenuCloak commands from this repository"
}

if [[ "$MODE" == "store" ]]; then
  install_from_store
elif [[ "$MODE" == "local" ]]; then
  install_from_repo
elif store_is_available; then
  install_from_store
else
  install_from_repo
fi
