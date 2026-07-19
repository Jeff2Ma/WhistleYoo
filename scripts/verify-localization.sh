#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
CATALOG="$ROOT_DIR/Sources/whistleYooCore/Resources/Localizable.xcstrings"
RESOURCE_DIR="$ROOT_DIR/Sources/whistleYooCore/Resources"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

xcrun xcstringstool compile \
  "$CATALOG" \
  --output-directory "$TEMP_DIR" \
  --serialization-format text

for language in en zh-Hans; do
  for filename in Localizable.strings Localizable.stringsdict; do
    cmp \
      "$TEMP_DIR/$language.lproj/$filename" \
      "$RESOURCE_DIR/$language.lproj/$filename"
    plutil -lint "$RESOURCE_DIR/$language.lproj/$filename"
  done
done

print "Localization catalog and generated SwiftPM resources are in sync."
