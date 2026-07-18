#!/bin/zsh

SPARKLE_ACCOUNT="com.devework.whistleyoo"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$ROOT_DIR/.sparkle/ed25519-private-key}"

sparkle_tool() {
  local tool="$1"
  local candidates=(
    "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/$tool"
    "$ROOT_DIR/build/SourcePackages/artifacts/sparkle/Sparkle/bin/$tool"
    "$ROOT_DIR/build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle/bin/$tool"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done

  print -u2 "Sparkle tool '$tool' was not found. Resolve packages first:"
  print -u2 "  swift package resolve"
  print -u2 "or:"
  print -u2 "  xcodebuild -resolvePackageDependencies -project whistleYoo.xcodeproj -scheme whistleYoo -clonedSourcePackagesDirPath build/SourcePackages"
  return 1
}

require_private_key() {
  if [[ ! -f "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
    print -u2 "Sparkle private key is missing: $SPARKLE_PRIVATE_KEY_FILE"
    print -u2 "Run ./scripts/generate-sparkle-keys.sh once, then back up that file securely."
    return 1
  fi
}
