#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_PATH="${1:-$ROOT_DIR/dist/WhistleYoo.app}"

[[ -d "$APP_PATH" ]] || {
  print -u2 "App bundle not found: $APP_PATH"
  exit 1
}

MACH_O_COUNT=0
while IFS= read -r -d $'\0' executable; do
  FILE_TYPE="$(file -b "$executable")"
  [[ "$FILE_TYPE" == *Mach-O* ]] || continue

  lipo "$executable" -verify_arch arm64 x86_64
  print "Universal: ${executable#$APP_PATH/}"
  MACH_O_COUNT=$((MACH_O_COUNT + 1))
done < <(find "$APP_PATH" -type f -perm -111 -print0)

if (( MACH_O_COUNT == 0 )); then
  print -u2 "No Mach-O executables found in: $APP_PATH"
  exit 1
fi

print "Verified $MACH_O_COUNT Mach-O executables with arm64 and x86_64 slices."
