#!/usr/bin/env bash
# iPhone app: generates the Xcode project (XcodeGen, hash-pinned), builds it
# for the simulator (self-test) and for devices (unsigned — proves that the
# device slice links; the user signs with their own Apple ID in Xcode), and
# packs build/Meteora-iOS.zip: the sources, the native libraries and the
# generated project, ready to open in Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806

mkdir -p build Vendor/download
XG=Vendor/download/xcodegen-$XCODEGEN_VERSION
if [ ! -x "$XG/bin/xcodegen" ]; then
  curl -fsSL --retry 3 -o "$XG.zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
  got=$(shasum -a 256 "$XG.zip" | cut -d' ' -f1)
  [ "$got" = "$XCODEGEN_SHA256" ] || { echo "HASH MISMATCH for xcodegen.zip ($got)"; exit 1; }
  rm -rf "$XG" && mkdir -p "$XG" && unzip -q "$XG.zip" -d "$XG.tmp" && mv "$XG.tmp/xcodegen/"* "$XG/" && rm -rf "$XG.tmp"
fi

BUILD=${GITHUB_RUN_NUMBER:-1}
(cd iOS && "$ROOT/$XG/bin/xcodegen" generate --spec project.yml)

COMMON=(-project iOS/Meteora.xcodeproj -scheme Meteora -configuration Debug
        CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$BUILD" -skipPackagePluginValidation)

echo "== simulator build"
# arm64 only: the libraries' simulator slices are for Apple silicon.
xcodebuild "${COMMON[@]}" -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' ARCHS=arm64 \
  -derivedDataPath build/ios-sim build > build/ios-sim.log 2>&1 || true
grep -E "error:|BUILD (SUCCEEDED|FAILED)" build/ios-sim.log | sort -u | head -40 || true
# Errors as annotations: readable through the API before the run ends.
grep -E "^/.*error:" build/ios-sim.log | sort -u | head -30 | while read -r l; do echo "::error title=ios-sim::${l#$ROOT/}"; done || true
grep -q "BUILD SUCCEEDED" build/ios-sim.log || { echo "simulator build failed"; exit 1; }

echo "== device build (unsigned)"
xcodebuild "${COMMON[@]}" -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios-dev build > build/ios-dev.log 2>&1 || true
grep -E "error:|BUILD (SUCCEEDED|FAILED)" build/ios-dev.log | sort -u | head -40 || true
grep -E "^/.*error:" build/ios-dev.log | sort -u | head -30 | while read -r l; do echo "::error title=ios-dev::${l#$ROOT/}"; done || true
grep -q "BUILD SUCCEEDED" build/ios-dev.log || { echo "device build failed"; exit 1; }
du -sh build/ios-dev/Build/Products/Debug-iphoneos/Meteora.app

echo "== Meteora-iOS.zip"
PKG=build/pkg/Meteora-iOS
rm -rf build/pkg && mkdir -p "$PKG"
git archive HEAD | tar -x -C "$PKG"
mkdir -p "$PKG/Vendor/models"
cp -R Vendor/ios "$PKG/Vendor/ios"
rm -f "$PKG/Vendor/ios/STAMP"
cp Vendor/models/silero_vad.onnx "$PKG/Vendor/models/"
cp -R iOS/Meteora.xcodeproj "$PKG/iOS/"
cp iOS/Meteora/Info.plist "$PKG/iOS/Meteora/Info.plist"
cp iOS/LiveActivity/Info.plist "$PKG/iOS/LiveActivity/Info.plist"
# Not needed for the iPhone build.
rm -rf "$PKG/motion" "$PKG/docs"
# Test fixtures aren't needed, but the package declares the folder.
rm -rf "$PKG/Tests/MeteoraCoreTests/Fixtures" && mkdir -p "$PKG/Tests/MeteoraCoreTests/Fixtures" \
  && touch "$PKG/Tests/MeteoraCoreTests/Fixtures/.keep"
cat > "$PKG/КАК УСТАНОВИТЬ НА iPHONE.txt" <<'TXT'
1. Откройте iOS/Meteora.xcodeproj в Xcode.
2. Подключите iPhone кабелем (или по Wi-Fi), выберите его вверху окна.
3. Слева выберите проект Meteora → цель Meteora → Signing & Capabilities → Team:
   ваш Apple ID (Add an Account…, если его там нет). То же для цели MeteoraLiveActivity.
4. Нажмите ▶ Run. На iPhone: Настройки → Основные → VPN и управление устройством →
   доверять разработчику. Включите «Режим разработчика», если iPhone попросит.
С бесплатным Apple ID приложение работает 7 дней — потом просто снова нажмите Run.
Записи, расшифровки и модели при этом сохраняются.
TXT
(cd build/pkg && zip -qry ../Meteora-iOS.zip Meteora-iOS)
du -h build/Meteora-iOS.zip
