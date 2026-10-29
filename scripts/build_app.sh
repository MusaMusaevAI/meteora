#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel), sandboxed, hardened-runtime
# Meteora.app in build/. Ad-hoc signed unless SIGN_IDENTITY is set.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-${GITHUB_RUN_NUMBER:-1}}"
APP=build/Meteora.app

scripts/fetch_vendor.sh
scripts/build_ffmpeg.sh   # no-op when Vendor/ffmpeg is up to date (CI cache)
scripts/build_llama.sh    # no-op when Vendor/llama is up to date (CI cache)
swift build -c release --arch arm64 --arch x86_64 --product Meteora
swift build -c release --arch arm64 --arch x86_64 --product MeteoraConverter
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Meteora" "$APP/Contents/MacOS/Meteora"
strip -x "$APP/Contents/MacOS/Meteora" || true
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Vendor/models/silero_vad.onnx "$APP/Contents/Resources/silero_vad.onnx"
cp Resources/THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/"
cp -R Resources/Onboarding "$APP/Contents/Resources/Onboarding"
cp Vendor/ffmpeg/CONFIGURE.txt "$APP/Contents/Resources/FFMPEG_BUILD.txt"
cp Vendor/ffmpeg/COPYING.LGPLv2.1 "$APP/Contents/Resources/FFMPEG_LICENSE_LGPL-2.1.txt"
cp Vendor/llama/LICENSE "$APP/Contents/Resources/LLAMA_CPP_LICENSE.txt"
cp Vendor/llama/CONFIGURE.txt "$APP/Contents/Resources/LLAMA_CPP_BUILD.txt"

# llama.cpp must be linked statically: with library validation an ad-hoc
# signed app can't load a third-party dylib, the app would not even launch.
LINKED=$(otool -L "$APP/Contents/MacOS/Meteora")
if grep -i -E 'llama|ggml' <<<"$LINKED"; then echo "Meteora links llama.cpp dynamically"; exit 1; fi

# Converter XPC service: its own bundle, Info.plist and sandbox; ffmpeg next
# to its executable (Contents/MacOS/ffmpeg) so it can be spawned from there.
XPC="$APP/Contents/XPCServices/com.musamusaev.meteora.converter.xpc"
mkdir -p "$XPC/Contents/MacOS"
cp "$BIN_DIR/MeteoraConverter" "$XPC/Contents/MacOS/MeteoraConverter"
strip -x "$XPC/Contents/MacOS/MeteoraConverter" || true
cp Vendor/ffmpeg/bin/ffmpeg "$XPC/Contents/MacOS/ffmpeg"
chmod 755 "$XPC/Contents/MacOS/ffmpeg"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/ConverterInfo.plist > "$XPC/Contents/Info.plist"

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

# Sign inside-out, all with hardened runtime:
#   ffmpeg (sandbox + inherit) → converter .xpc (sandbox only) → app.
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none \
  --identifier com.musamusaev.meteora.converter.ffmpeg \
  --entitlements Resources/ffmpeg.entitlements -s "$IDENTITY" "$XPC/Contents/MacOS/ffmpeg"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/MeteoraConverter.entitlements -s "$IDENTITY" "$XPC"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/Meteora.entitlements -s "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - || true
echo "converter service entitlements:"
codesign -d --entitlements - --xml "$XPC" 2>/dev/null | plutil -p - || true
echo "ffmpeg entitlements:"
codesign -d --entitlements - --xml "$XPC/Contents/MacOS/ffmpeg" 2>/dev/null | plutil -p - || true
lipo -info "$APP/Contents/MacOS/Meteora"
lipo -info "$XPC/Contents/MacOS/MeteoraConverter"
lipo -info "$XPC/Contents/MacOS/ffmpeg"
du -sh "$APP"
