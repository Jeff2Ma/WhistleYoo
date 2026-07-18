#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

swift test -Xswiftc -warnings-as-errors
IPROXY_RUN_INTEGRATION=1 swift test --filter WhistleIntegrationTests
./build.sh

APP="$ROOT_DIR/dist/WhistleYoo.app"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
lipo "$APP/Contents/MacOS/WhistleYoo" -verify_arch arm64 x86_64

print "All verification checks passed."
