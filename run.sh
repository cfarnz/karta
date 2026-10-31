#!/bin/bash
# Build, install and launch Karta on the simulator.
#
#   ./run.sh                     release build, plain launch
#   ./run.sh --debug             debug build instead
#   ./run.sh -seedDemoRoute -hillshade -slopeOverlay -useUSGS
#
# Any argument starting with "-" that isn't --debug is passed to the app.

set -euo pipefail
cd "$(dirname "$0")"

CONFIG=Release
APP_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=Debug ;;
    --release) CONFIG=Release ;;
    *) APP_ARGS+=("$arg") ;;
  esac
done

DEVICE_NAME="Karta"
BUNDLE_ID="com.cfarnz.karta"

# Reuse a simulator if one exists, otherwise make one.
UDID=$(xcrun simctl list devices available \
       | grep -oE '\(([0-9A-F-]{36})\)' | tr -d '()' | head -1 || true)
if [ -z "$UDID" ]; then
  echo "==> creating a simulator"
  RUNTIME=$(xcrun simctl list runtimes | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS[0-9.-]+' | head -1)
  TYPE=$(xcrun simctl list devicetypes | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-1[0-9]-Pro' | head -1)
  UDID=$(xcrun simctl create "$DEVICE_NAME" "$TYPE" "$RUNTIME")
fi
echo "==> simulator $UDID"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" >/dev/null 2>&1 || true

echo "==> building $CONFIG"
xcodebuild -project Karta.xcodeproj -scheme Karta \
  -sdk iphonesimulator -destination "id=$UDID" \
  -configuration "$CONFIG" build 2>&1 | grep -E "error:|warning:|BUILD " || true

APP=$(xcodebuild -project Karta.xcodeproj -scheme Karta \
      -sdk iphonesimulator -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')

echo "==> installing $APP"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

echo "==> launching"
xcrun simctl launch "$UDID" "$BUNDLE_ID" "${APP_ARGS[@]+"${APP_ARGS[@]}"}"

# Simulator.app is not installed with this Xcode; DeviceHub is the way in.
open "/Applications/Xcode.app/Contents/Applications/DeviceHub.app" 2>/dev/null || true
