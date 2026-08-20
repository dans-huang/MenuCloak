#!/bin/bash
# Install MenuCloak, its Raycast commands, and start the app quietly at login.
# Uninstall: launchctl bootout gui/$(id -u)/com.dans.menucloak
set -euo pipefail
cd "$(dirname "$0")"

is_official_remote() {
  case "$1" in
    https://github.com/dans-huang/MenuCloak|https://github.com/dans-huang/MenuCloak.git|\
git@github.com:dans-huang/MenuCloak|git@github.com:dans-huang/MenuCloak.git|\
ssh://git@github.com/dans-huang/MenuCloak|ssh://git@github.com/dans-huang/MenuCloak.git)
      return 0
      ;;
  esac
  return 1
}

checkout_contains_commit() {
  local repo_root="$1" candidate required
  candidate="$(git -C "$repo_root" rev-parse "$2")"
  required="$(git -C "$repo_root" rev-parse "$3")"
  git -C "$repo_root" merge-base --is-ancestor "$required" "$candidate"
}

validate_install_source() {
  [ "${MENUCLOAK_ALLOW_UNVERIFIED_SOURCE:-}" = "1" ] && return 0

  local repo_root source_remote script_path
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -z "$repo_root" ] && return 0
  if [ "$PWD" = "$repo_root" ]; then
    script_path="install-launchagent.sh"
  else
    script_path="${PWD#"$repo_root"/}/install-launchagent.sh"
  fi
  git -C "$repo_root" ls-files --error-unmatch "$script_path" >/dev/null 2>&1 || return 0
  source_remote="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
  [ -z "$source_remote" ] && return 0

  if ! is_official_remote "$source_remote"; then
    echo "error: refusing to install MenuCloak from unrelated repository $source_remote" >&2
    echo "Install from https://github.com/dans-huang/MenuCloak instead." >&2
    return 1
  fi

  if ! GIT_TERMINAL_PROMPT=0 git -C "$repo_root" fetch origin main --quiet 2>/dev/null; then
    echo "error: could not verify the latest MenuCloak version on origin/main" >&2
    echo "Check the network, or set MENUCLOAK_ALLOW_UNVERIFIED_SOURCE=1 to override." >&2
    return 1
  fi
  if ! checkout_contains_commit "$repo_root" HEAD origin/main; then
    echo "error: refusing to install a MenuCloak checkout without the latest origin/main" >&2
    echo "Update or rebase onto origin/main, then install again." >&2
    return 1
  fi
}

if [ "${1:-}" = "--selftest" ]; then
  is_official_remote "https://github.com/dans-huang/MenuCloak.git"
  is_official_remote "git@github.com:dans-huang/MenuCloak.git"
  ! is_official_remote "https://github.com/dans-huang/CC.git"
  checkout_contains_commit "$(pwd)" HEAD HEAD
  if git rev-parse HEAD^ >/dev/null 2>&1; then
    checkout_contains_commit "$(pwd)" HEAD HEAD^
    ! checkout_contains_commit "$(pwd)" HEAD^ HEAD
  fi
  validate_install_source
  echo "menucloak installer selftest passed"
  exit 0
fi

USE_PREBUILT=false
if [[ "${1:-}" == "--prebuilt" ]]; then
  USE_PREBUILT=true
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "usage: $0 [--prebuilt]" >&2
  exit 2
fi

validate_install_source
SOURCE_APP="${MENUCLOAK_SOURCE_APP:-$(pwd)/MenuCloak.app}"
if [[ "$USE_PREBUILT" == true ]]; then
  if [[ ! -x "$SOURCE_APP/Contents/MacOS/MenuCloak" ]]; then
    echo "menucloak: bundled MenuCloak.app is missing or incomplete" >&2
    exit 1
  fi
  if ! plutil -extract MenuCloakGoogleClientSecret raw -o - \
    "$SOURCE_APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "menucloak: bundled app is not a Google-enabled release build" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$SOURCE_APP"
  echo "menucloak: verified bundled release app"
else
  ./build.sh
fi

./scripts/install-raycast-extension.sh --preflight

if [[ "${MENUCLOAK_INSTALL_DRY_RUN:-0}" == "1" ]]; then
  echo "menucloak: install dry run passed"
  exit 0
fi

./scripts/install-raycast-extension.sh

if [[ -n "${MENUCLOAK_APPLICATIONS_DIR:-}" ]]; then
  APPLICATIONS_DIR="$MENUCLOAK_APPLICATIONS_DIR"
elif [[ -w /Applications ]] && \
  { [[ ! -e /Applications/MenuCloak.app ]] || [[ -w /Applications/MenuCloak.app ]]; }; then
  APPLICATIONS_DIR="/Applications"
else
  APPLICATIONS_DIR="$HOME/Applications"
  echo "menucloak: using $APPLICATIONS_DIR for this standard user account"
fi
mkdir -p "$APPLICATIONS_DIR"
APP="$APPLICATIONS_DIR/MenuCloak.app"
ditto "$SOURCE_APP" "$APP"
BIN="$APP/Contents/MacOS/MenuCloak"
LAUNCH_AGENTS_DIR="${MENUCLOAK_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$LAUNCH_AGENTS_DIR/com.dans.menucloak.plist"
mkdir -p "$LAUNCH_AGENTS_DIR"
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
