#!/usr/bin/env bash
# Packs build/Volant.app into one compressed, drag-to-install DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
DMG="build/Volant-$VERSION.dmg"
rm -f "$DMG" build/Volant.dmg
tiffutil -cathidpicheck Resources/dmg/background.png Resources/dmg/background@2x.png -out build/dmg-background.tiff

if command -v create-dmg >/dev/null || brew install create-dmg >/dev/null 2>&1; then
  for attempt in 1 2 3; do
    if create-dmg --volname "Volant" --volicon build/Volant.app/Contents/Resources/AppIcon.icns \
         --background build/dmg-background.tiff --window-pos 200 120 --window-size 660 440 \
         --icon-size 112 --icon "Volant.app" 170 190 --hide-extension "Volant.app" \
         --app-drop-link 490 190 --no-internet-enable --format ULFO \
         "$DMG" build/Volant.app; then break; fi
    echo "create-dmg attempt $attempt failed"; rm -f "$DMG"; sleep 3
  done
fi
if [ ! -f "$DMG" ]; then
  echo "fallback: plain hdiutil DMG"
  rm -rf build/dmg && mkdir -p build/dmg && cp -R build/Volant.app build/dmg/ && ln -s /Applications build/dmg/Applications
  hdiutil create -volname Volant -srcfolder build/dmg -ov -format ULFO "$DMG"
fi
codesign --force -s "${SIGN_IDENTITY:--}" "$DMG" || true
hdiutil verify "$DMG"
cp "$DMG" build/Volant.dmg
shasum -a 256 "$DMG" | tee build/Volant.dmg.sha256
ls -la build/*.dmg
