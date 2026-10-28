#!/usr/bin/env bash
# Packs build/Volant.app into one compressed drag-to-install DMG with a styled
# window. Uses only tools that ship with macOS (hdiutil, osascript, tiffutil).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
DMG="build/Volant-$VERSION.dmg"
RW=build/volant-rw.dmg
VOL="Volant"
rm -f "$DMG" "$RW" build/Volant.dmg
tiffutil -cathidpicheck Resources/dmg/background.png Resources/dmg/background@2x.png -out build/dmg-background.tiff

rm -rf build/dmg && mkdir -p build/dmg/.background
cp -R build/Volant.app build/dmg/
cp build/dmg-background.tiff build/dmg/.background/background.tiff
ln -s /Applications build/dmg/Applications
hdiutil create -volname "$VOL" -srcfolder build/dmg -fs HFS+ -format UDRW -ov "$RW"
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1}')
MNT="/Volumes/$VOL"
cp build/Volant.app/Contents/Resources/AppIcon.icns "$MNT/.VolumeIcon.icns" && SetFile -a C "$MNT" 2>/dev/null || true

styled=0
for attempt in 1 2 3; do
  if osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 560}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Volant.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
  then styled=1; break; fi
  echo "Finder styling attempt $attempt failed"; sleep 3
done
echo "styled=$styled"
chmod -Rf go-w "$MNT" || true
sync
hdiutil detach "$DEV" -quiet || hdiutil detach "$DEV" -force
hdiutil convert "$RW" -format ULFO -o "$DMG"
rm -f "$RW"
codesign --force -s "${SIGN_IDENTITY:--}" "$DMG"
hdiutil verify "$DMG"
cp "$DMG" build/Volant.dmg
shasum -a 256 build/Volant.dmg | tee build/Volant.dmg.sha256
ls -la build/*.dmg
