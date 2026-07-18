#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
source "$ROOT_DIR/scripts/sparkle-common.sh"

GENERATE_KEYS="$(sparkle_tool generate_keys)"
KEY_DIR="${SPARKLE_PRIVATE_KEY_FILE:h}"
TEMP_KEYCHAIN="$KEY_DIR/key-generation.keychain-db"
ORIGINAL_KEYCHAIN="$(security default-keychain -d user | tr -d ' \"')"
TEMP_PASSWORD="$(uuidgen)$(uuidgen)"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

restore_keychain() {
  security default-keychain -d user -s "$ORIGINAL_KEYCHAIN" >/dev/null 2>&1 || true
  security delete-keychain "$TEMP_KEYCHAIN" >/dev/null 2>&1 || rm -f "$TEMP_KEYCHAIN"
}
trap restore_keychain EXIT

rm -f "$TEMP_KEYCHAIN"
security create-keychain -p "$TEMP_PASSWORD" "$TEMP_KEYCHAIN"
security unlock-keychain -p "$TEMP_PASSWORD" "$TEMP_KEYCHAIN"
security set-keychain-settings -lut 3600 "$TEMP_KEYCHAIN"
security default-keychain -d user -s "$TEMP_KEYCHAIN"

if [[ -f "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
  "$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -f "$SPARKLE_PRIVATE_KEY_FILE" >/dev/null
  print "Using the existing private key at $SPARKLE_PRIVATE_KEY_FILE"
else
  "$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT"
  "$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -x "$SPARKLE_PRIVATE_KEY_FILE"
  chmod 600 "$SPARKLE_PRIVATE_KEY_FILE"
  print "Private key exported to $SPARKLE_PRIVATE_KEY_FILE (gitignored; back it up securely)."
fi

print "SUPublicEDKey: $("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)"
