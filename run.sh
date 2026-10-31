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
#
# Everything here reads simctl's JSON rather than its text. The text output
# was parsed with regexes that broke on the iOS 27 naming: runtime
# identifiers gained a device suffix (...iOS-27-2-iPhone19-4), and a pattern
# of 'iOS[0-9.-]+' clipped it to an invalid 'iOS-27-2-'.
UDID=$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
print(next((d['udid'] for v in devices.values() for d in v), ''))
")

if [ -z "$UDID" ]; then
  echo "==> creating a simulator"
  RUNTIME=$(xcrun simctl list runtimes -j 2>/dev/null | python3 -c "
import json, sys
runtimes = [r for r in json.load(sys.stdin)['runtimes']
            if r.get('isAvailable') and r.get('platform') == 'iOS']
print(runtimes[-1]['identifier'] if runtimes else '')
")
  TYPE=$(xcrun simctl list devicetypes -j 2>/dev/null | python3 -c "
import json, sys
types = [t for t in json.load(sys.stdin)['devicetypes']
         if 'iPhone' in t['name'] and 'Pro' in t['name']]
print(types[-1]['identifier'] if types else '')
")
  if [ -z "$RUNTIME" ] || [ -z "$TYPE" ]; then
    echo "no usable iOS runtime or iPhone device type; check Xcode's installed platforms" >&2
    exit 1
  fi
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
