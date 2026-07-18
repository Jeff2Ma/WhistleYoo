#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
source "$ROOT_DIR/scripts/sparkle-common.sh"
require_private_key

if (( $# != 1 )); then
  print -u2 "Usage: $0 /path/to/WhistleYoo-version.zip-or.dmg"
  exit 2
fi

ARCHIVE="${1:A}"
[[ -f "$ARCHIVE" ]] || { print -u2 "Archive not found: $ARCHIVE"; exit 2; }

SIGN_UPDATE="$(sparkle_tool sign_update)"
"$SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$ARCHIVE"
