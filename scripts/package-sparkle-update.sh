#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
source "$ROOT_DIR/scripts/sparkle-common.sh"
require_private_key

FORMAT="${1:-zip}"
if [[ "$FORMAT" != "zip" && "$FORMAT" != "dmg" ]]; then
  print -u2 "Usage: $0 [zip|dmg]"
  exit 2
fi

"$ROOT_DIR/build.sh" --clean --no-install

APP_PATH="$ROOT_DIR/dist/WhistleYoo.app"
[[ -d "$APP_PATH" ]] || { print -u2 "Built app not found: $APP_PATH"; exit 1; }

SHORT_VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString)"
BUNDLE_VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleVersion)"
ARCHIVE_BASENAME="WhistleYoo-$SHORT_VERSION"
UPDATES_DIR="$ROOT_DIR/updates"
ARCHIVE_PATH="$UPDATES_DIR/$ARCHIVE_BASENAME.$FORMAT"

mkdir -p "$UPDATES_DIR"
rm -f "$UPDATES_DIR/$ARCHIVE_BASENAME.zip" "$UPDATES_DIR/$ARCHIVE_BASENAME.dmg"

if [[ "$FORMAT" == "zip" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
else
  STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WhistleYoo-update.XXXXXX")"
  trap 'rm -rf "$STAGE_DIR"' EXIT
  ditto "$APP_PATH" "$STAGE_DIR/WhistleYoo.app"
  hdiutil create -quiet -fs HFS+ -format UDZO -volname "WhistleYoo $SHORT_VERSION" -srcfolder "$STAGE_DIR" "$ARCHIVE_PATH"
fi

GENERATE_APPCAST="$(sparkle_tool generate_appcast)"
DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/Jeff2Ma/WhistleYoo/releases/download/v$SHORT_VERSION/}"
"$GENERATE_APPCAST" \
  --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "https://github.com/Jeff2Ma/WhistleYoo" \
  --maximum-versions 10 \
  -o "$UPDATES_DIR/appcast.xml" \
  "$UPDATES_DIR"

print "Prepared Sparkle release:"
print "  archive: $ARCHIVE_PATH"
print "  appcast: $UPDATES_DIR/appcast.xml"
print "  version: $SHORT_VERSION (build $BUNDLE_VERSION)"
print "Upload the archive and any generated .delta files to: $DOWNLOAD_URL_PREFIX"
print "Commit updates/appcast.xml after verifying its URLs."
