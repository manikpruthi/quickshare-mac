#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="QuickShare-Mac"
BUNDLE_NAME="QuickShare-Mac"
BUILD_DIR="${QUICKSHARE_MAC_BUILD_DIR:-$HOME/Library/Caches/QuickShareMacBuild}"
APP="$BUILD_DIR/$BUNDLE_NAME.app"
MODE="${1:-debug}"

SDK="$(xcrun --show-sdk-path)"

if [ "$MODE" = "release" ] || [ "$MODE" = "--release" ]; then
    SPM_CONFIG=release
else
    SPM_CONFIG=debug
fi

# 1. swift build (fetches SwiftProtobuf + SwiftECC once, caches in .build)
echo "Building Swift package ($SPM_CONFIG)..."
swift build -c "$SPM_CONFIG" 2>&1 | tail -3

# 2. assemble .app around the SPM binary
BIN="$(swift build -c "$SPM_CONFIG" --show-bin-path)/QuickShare-Mac"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/QuickShare-Mac.icns ]; then
    cp Resources/QuickShare-Mac.icns "$APP/Contents/Resources/QuickShare-Mac.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
touch "$BUILD_DIR/.metadata_never_index"

SWIFTBIN="$APP/Contents/MacOS/$APP_NAME"
if [ "$MODE" = "test" ] || [ "$MODE" = "--test" ]; then
    echo ""
    "$SWIFTBIN" --self-test
    exit 0
fi

echo "Built $APP"
file "$SWIFTBIN" | head -1
