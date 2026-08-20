#!/bin/bash
# Install MenuCloak's companion Raycast commands from the Store, a release bundle,
# or a temporary source build while Store review is pending.
set -euo pipefail

ACTION="${1:---install}"
if [[ "$ACTION" != "--install" && "$ACTION" != "--preflight" ]]; then
  echo "raycast: usage: $0 [--preflight|--install]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTENSION_DIR="$PROJECT_DIR/raycast-extension"
BUNDLED_EXTENSION_DIR="$PROJECT_DIR/raycast-extension-built"
STORE_URL="${MENUCLOAK_RAYCAST_STORE_URL:-https://www.raycast.com/dans_huang/menucloak}"
MODE="${MENUCLOAK_RAYCAST_MODE:-auto}"
RAYCAST_APP="${MENUCLOAK_RAYCAST_APP:-}"

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

if [[ -z "$RAYCAST_APP" ]]; then
  for candidate in "/Applications/Raycast.app" "$HOME/Applications/Raycast.app"; do
    if [[ -d "$candidate" ]]; then
      RAYCAST_APP="$candidate"
      break
    fi
  done
fi

if [[ -z "$RAYCAST_APP" || ! -d "$RAYCAST_APP" ]]; then
  echo "raycast: not installed; skipped companion commands"
  exit 0
fi

store_is_available() {
  local status
  status="$(curl --location --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 3 --max-time 8 "$STORE_URL" 2>/dev/null || true)"
  [[ "$status" == "200" ]]
}

validate_extension() {
  local extension_path="$1"
  local manifest="$extension_path/package.json"
  if [[ ! -f "$manifest" ]]; then
    echo "raycast: extension manifest is missing from $extension_path" >&2
    return 1
  fi
  local command_count
  command_count="$(/usr/bin/plutil -extract commands raw -o - "$manifest" 2>/dev/null || true)"
  if [[ "$command_count" -ne 5 ]]; then
    echo "raycast: expected 5 MenuCloak commands, found $command_count" >&2
    return 1
  fi
  local command
  for command in set-focus toggle turn-on turn-off open-settings; do
    if [[ ! -f "$extension_path/$command.js" ]]; then
      echo "raycast: compiled command is missing: $command.js" >&2
      return 1
    fi
  done
}

if [[ "$MODE" == "store" ]]; then
  INSTALL_SOURCE="store"
elif [[ "$MODE" == "local" ]]; then
  INSTALL_SOURCE="local"
elif store_is_available; then
  INSTALL_SOURCE="store"
elif [[ -d "$BUNDLED_EXTENSION_DIR" ]]; then
  INSTALL_SOURCE="bundle"
else
  INSTALL_SOURCE="local"
fi

preflight() {
  case "$INSTALL_SOURCE" in
    store)
      if ! store_is_available; then
        echo "raycast: official Store page is not available yet" >&2
        return 1
      fi
      ;;
    bundle)
      validate_extension "$BUNDLED_EXTENSION_DIR"
      ;;
    local)
      if [[ ! -f "$EXTENSION_DIR/package-lock.json" ]]; then
        echo "raycast: bundled extension source is missing from $EXTENSION_DIR" >&2
        return 1
      fi
      if ! command -v npm >/dev/null 2>&1; then
        echo "raycast: Store listing is not live yet and npm is unavailable" >&2
        echo "raycast: install Node.js, then run this source installer again" >&2
        return 1
      fi
      ;;
  esac
  echo "raycast: preflight passed ($INSTALL_SOURCE)"
}

if [[ "$ACTION" == "--preflight" ]]; then
  preflight
  exit 0
fi
preflight >/dev/null

install_from_store() {
  open "$STORE_URL"
  echo "raycast: opened the official MenuCloak Store page"
  echo "raycast: confirm Install once in Raycast to finish"
}

install_from_bundle() {
  local destination="$HOME/.config/raycast/extensions/menucloak"
  mkdir -p "$(dirname "$destination")"
  ditto "$BUNDLED_EXTENSION_DIR" "$destination"
  validate_extension "$destination"
  open "$RAYCAST_APP"
  echo "raycast: installed and verified 5 bundled MenuCloak commands"
}

install_from_repo() (
  local build_root
  build_root="$(mktemp -d)"
  cleanup() {
    /usr/bin/trash "$build_root" 2>/dev/null || true
  }
  trap cleanup EXIT
  mkdir -p "$build_root/raycast-extension"
  tar -c --exclude node_modules --exclude .raycast-swift-build \
    -f - -C "$EXTENSION_DIR" . | tar -x -f - -C "$build_root/raycast-extension"
  (
    cd "$build_root/raycast-extension"
    npm ci
    npm run lint
    npm run build
  )
  validate_extension "$HOME/.config/raycast/extensions/menucloak"
  open "$RAYCAST_APP"
  echo "raycast: installed and verified 5 MenuCloak commands from source"
)

case "$INSTALL_SOURCE" in
  store) install_from_store ;;
  bundle) install_from_bundle ;;
  local) install_from_repo ;;
esac
