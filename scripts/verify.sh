#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

swift test -Xswiftc -warnings-as-errors
WHISTLEYOO_RUN_INTEGRATION=1 swift test --filter WhistleIntegrationTests
./build.sh

APP="$ROOT_DIR/dist/WhistleYoo.app"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
./scripts/verify-universal-app.sh "$APP"

print "All verification checks passed."
