#!/bin/bash
# Point MenuCloak at an existing Google OAuth token without copying its credentials.
set -euo pipefail

SOURCE="${1:-}"
if [[ -z "$SOURCE" || "$SOURCE" != /* || ! -f "$SOURCE" ]]; then
	echo "usage: $0 /absolute/path/to/google-oauth-token.json" >&2
	exit 1
fi

for key in client_id client_secret refresh_token; do
	if ! /usr/bin/plutil -extract "$key" raw "$SOURCE" >/dev/null 2>&1; then
		echo "missing $key in $SOURCE" >&2
		exit 1
	fi
done
/bin/chmod go-rwx "$SOURCE"

CONFIG_DIR="$HOME/.config/menucloak"
DESTINATION="$CONFIG_DIR/google-calendar.json"
/bin/mkdir -p "$CONFIG_DIR"

if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
	if [[ -L "$DESTINATION" && "$(/usr/bin/readlink "$DESTINATION")" == "$SOURCE" ]]; then
		echo "configured: $DESTINATION"
		exit 0
	fi
	echo "refusing to replace existing $DESTINATION" >&2
	exit 1
fi

/bin/ln -s "$SOURCE" "$DESTINATION"
echo "configured: $DESTINATION"
