#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SCRIPT_NAME="${0:t}"
source "$ROOT_DIR/scripts/sparkle-common.sh"

FORMAT="zip"
VERSION=""
BUILD_NUMBER=""

usage() {
  print -u2 "Usage: $SCRIPT_NAME [zip|dmg] [--version x.y.z] [--build-number n]"
}

if (( $# > 0 )) && [[ "$1" != --* ]]; then
  FORMAT="$1"
  shift
fi
if [[ "$FORMAT" != "zip" && "$FORMAT" != "dmg" ]]; then
  usage
  exit 2
fi

while (( $# > 0 )); do
  case "$1" in
    --version)
      VERSION="${2:?--version requires a value}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:?--build-number requires a value}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown option: $1"
      usage
      exit 2
      ;;
  esac
done

require_private_key

BUILD_ARGS=(--clean --no-install)
if [[ -n "$VERSION" ]]; then
  BUILD_ARGS+=(--version "$VERSION")
fi
if [[ -n "$BUILD_NUMBER" ]]; then
  BUILD_ARGS+=(--build-number "$BUILD_NUMBER")
fi
"$ROOT_DIR/build.sh" "${BUILD_ARGS[@]}"

APP_PATH="$ROOT_DIR/dist/WhistleYoo.app"
[[ -d "$APP_PATH" ]] || { print -u2 "Built app not found: $APP_PATH"; exit 1; }

SHORT_VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString)"
BUNDLE_VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleVersion)"
if [[ -n "$VERSION" && "$SHORT_VERSION" != "$VERSION" ]]; then
  print -u2 "Built version mismatch: expected $VERSION, got $SHORT_VERSION"
  exit 1
fi
if [[ -n "$BUILD_NUMBER" && "$BUNDLE_VERSION" != "$BUILD_NUMBER" ]]; then
  print -u2 "Built build-number mismatch: expected $BUILD_NUMBER, got $BUNDLE_VERSION"
  exit 1
fi
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
[[ "$DOWNLOAD_URL_PREFIX" == */ ]] || DOWNLOAD_URL_PREFIX+="/"
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
