#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
DERIVED_DATA="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
SIGN_IDENTITY="-"
CLEAN=0
INSTALL_DIR="/Applications"
NO_INSTALL=0
MARKETING_VERSION_OVERRIDE=""
BUILD_NUMBER_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: ./build.sh [options]

Options:
  --sign <identity>       Sign with a Developer ID identity (default: ad-hoc)
  --version <x.y.z>       Override MARKETING_VERSION for this build
  --build-number <n>      Override CURRENT_PROJECT_VERSION for this build
  --clean                 Remove existing build and dist directories first
  --install-dir <path>    Install into the given directory (default: /Applications)
  --no-install            Build without installing the app
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --sign)
      SIGN_IDENTITY="${2:?--sign requires a Developer ID identity}"
      shift 2
      ;;
    --version)
      MARKETING_VERSION_OVERRIDE="${2:?--version requires a value}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER_OVERRIDE="${2:?--build-number requires a value}"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --install-dir)
      INSTALL_DIR="${2:?--install-dir requires a path}"
      shift 2
      ;;
    --no-install)
      NO_INSTALL=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$MARKETING_VERSION_OVERRIDE" && ! "$MARKETING_VERSION_OVERRIDE" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "Invalid version '$MARKETING_VERSION_OVERRIDE'; expected x.y.z"
  exit 2
fi
if [[ -n "$BUILD_NUMBER_OVERRIDE" && ! "$BUILD_NUMBER_OVERRIDE" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "Invalid build number '$BUILD_NUMBER_OVERRIDE'; expected a positive integer"
  exit 2
fi

if (( CLEAN )); then
  rm -rf "$DERIVED_DATA" "$DIST_DIR"
fi

mkdir -p "$DIST_DIR"
XCODEBUILD_ARGS=(
  -project "$ROOT_DIR/whistleYoo.xcodeproj" \
  -scheme whistleYoo \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  "ARCHS=arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO
)
if [[ -n "$MARKETING_VERSION_OVERRIDE" ]]; then
  XCODEBUILD_ARGS+=("MARKETING_VERSION=$MARKETING_VERSION_OVERRIDE")
fi
if [[ -n "$BUILD_NUMBER_OVERRIDE" ]]; then
  XCODEBUILD_ARGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER_OVERRIDE")
fi
xcodebuild "${XCODEBUILD_ARGS[@]}" build

SOURCE_APP="$DERIVED_DATA/Build/Products/Release/WhistleYoo.app"
TARGET_APP="$DIST_DIR/WhistleYoo.app"
rm -rf "$TARGET_APP"
cp -R "$SOURCE_APP" "$TARGET_APP"

SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ROOT_DIR/Sources/whistleYooApp/Resources/whistleYoo.entitlements")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$TARGET_APP"
codesign --verify --deep --strict --verbose=2 "$TARGET_APP"
lipo -info "$TARGET_APP/Contents/MacOS/WhistleYoo"
print "Built: $TARGET_APP"

# 安装：退出当前运行的实例并覆盖到应用目录
if (( ! NO_INSTALL )); then
  APP_NAME="WhistleYoo"
  APP_BUNDLE_ID="com.devework.whistleyoo"
  EXEC_MARKER="[Ww]histleYoo.app/Contents/MacOS/[Ww]histleYoo"
  INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"
  LEGACY_INSTALL_APP="$INSTALL_DIR/whistleYoo.app"

  [[ -n "$INSTALL_DIR" && "$INSTALL_APP" == *.app ]] || {
    print -u2 "Invalid install dir: $INSTALL_DIR"
    exit 2
  }

  # 优先优雅退出：app 的 applicationShouldTerminate 会先恢复系统代理、再停止 Whistle 引擎，
  # 避免强制 kill 留下孤立的 whistle daemon（即健康检查失同步的根因）。
  if pgrep -f "$EXEC_MARKER" >/dev/null 2>&1; then
    print "Quitting running $APP_NAME (bundle id $APP_BUNDLE_ID)..."
    osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" 2>/dev/null || true
    # 最坏情况引擎停止约 15s + 健康轮询 10s，给 30s 优雅窗口
    grace=0
    while (( grace < 150 )) && pgrep -f "$EXEC_MARKER" >/dev/null 2>&1; do
      sleep 0.2
      grace=$((grace + 1))
    done
    # 优雅退出超时则强制结束
    if pgrep -f "$EXEC_MARKER" >/dev/null 2>&1; then
      print -u2 "Graceful quit timed out, force killing..."
      pkill -9 -f "$EXEC_MARKER" 2>/dev/null || true
      sleep 1
    fi
  fi

  rm -rf "$INSTALL_APP"
  if [[ "$LEGACY_INSTALL_APP" != "$INSTALL_APP" && -e "$LEGACY_INSTALL_APP" ]]; then
    rm -rf "$LEGACY_INSTALL_APP"
  fi
  cp -R "$TARGET_APP" "$INSTALL_APP"
  print "Installed: $INSTALL_APP"
fi
