#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel), sandboxed, hardened-runtime
# Meteora.app in build/. Ad-hoc signed unless SIGN_IDENTITY is set.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-${GITHUB_RUN_NUMBER:-1}}"
APP=build/Meteora.app

scripts/fetch_vendor.sh
swift build -c release --arch arm64 --arch x86_64 --product Meteora
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Meteora" "$APP/Contents/MacOS/Meteora"
strip -x "$APP/Contents/MacOS/Meteora" || true
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Vendor/models/silero_vad.onnx "$APP/Contents/Resources/silero_vad.onnx"
cp Resources/THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/"
cp -R Resources/Onboarding "$APP/Contents/Resources/Onboarding"

# Legacy icon for macOS 14–15
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Icon Composer icon (light/dark) for macOS 26+, compiled into Assets.car
mkdir -p build/actool
if xcrun actool --compile build/actool --platform macosx --minimum-deployment-target 14.0 \
     --app-icon AppIcon --output-partial-info-plist build/actool/partial.plist \
     --errors --warnings --notices --output-format human-readable-text \
     Resources/AppIcon.icon > build/actool/log.txt 2>&1 && [ -f build/actool/Assets.car ]; then
  cp build/actool/Assets.car "$APP/Contents/Resources/Assets.car"
  echo "actool: Assets.car compiled from AppIcon.icon"
else
  echo "actool: .icon not compiled, legacy icon only"; cat build/actool/log.txt || true
fi

# Sign: hardened runtime + sandbox entitlements
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/Meteora.entitlements -s "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - || true
lipo -info "$APP/Contents/MacOS/Meteora"
du -sh "$APP"
