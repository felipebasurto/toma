#!/bin/sh
# Builds Toma.app from the Swift package.
#   ./build.sh       →  ./Toma.app
#   ./build.sh dmg   →  ./Toma.app and ./Toma.dmg (drag-to-Applications disk image)
set -eu
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

# Universal binary: Apple silicon and Intel.
swift build -c release --arch arm64 --arch x86_64
APP=Toma.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/Toma "$APP/Contents/MacOS/Toma"
cp Resources/Toma.icns "$APP/Contents/Resources/Toma.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.toma</string>
  <key>CFBundleName</key><string>Toma</string>
  <key>CFBundleDisplayName</key><string>Toma</string>
  <key>CFBundleExecutable</key><string>Toma</string>
  <key>CFBundleIconFile</key><string>Toma</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Felipe Basurto. Licencia MIT.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Toma graba la zona de la pantalla que eliges.</string>
  <key>NSMicrophoneUsageDescription</key><string>Toma graba tu voz junto a la pantalla cuando eliges «Sonido del Mac y micrófono».</string>
</dict></plist>
PLIST

# Developer ID Application is what other Macs trust (the DMG is downloaded). Without it, fall back to
# Apple Development (this Mac only), then ad hoc. TCC keys the Screen Recording grant to the signature,
# so a stable identity keeps the permission across rebuilds.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
TIMESTAMP=--timestamp
if [ -z "$IDENTITY" ]; then
  TIMESTAMP=--timestamp=none
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
# Hardened runtime blocks the microphone unless the entitlement says otherwise.
ENTITLEMENTS=$(mktemp)
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
ENT
codesign --force --options runtime $TIMESTAMP --entitlements "$ENTITLEMENTS" --sign "${IDENTITY:--}" --identifier app.toma "$APP"
rm -f "$ENTITLEMENTS"
echo "Listo: $APP ($VERSION)"

[ "${1:-}" = "dmg" ] || exit 0

# Disk image: Toma.app next to an Applications shortcut, laid out by Finder on a white
# background with an arrow (Resources/dmg-background.tiff, drawn by scripts/background.swift).
DMG=Toma.dmg
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Aplicaciones"
rm -f "$DMG" Toma-rw.dmg
hdiutil create -quiet -volname Toma -srcfolder "$STAGE" -fs HFS+ -format UDRW -size 20m Toma-rw.dmg
rm -rf "$STAGE"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen Toma-rw.dmg | awk '/Apple_HFS/ {print $1}')
cp Resources/Toma.icns /Volumes/Toma/.VolumeIcon.icns
mkdir -p /Volumes/Toma/.background && cp Resources/dmg-background.tiff /Volumes/Toma/.background/background.tiff
SetFile -a C /Volumes/Toma 2>/dev/null || true
osascript <<APPLESCRIPT || echo "(sin maquetar: Finder no respondió)"
tell application "Finder"
  tell disk "Toma"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 740, 440}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Toma.app" of container window to {140, 150}
    set position of item "Aplicaciones" of container window to {400, 150}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
sync
hdiutil detach -quiet "$DEVICE"
hdiutil convert -quiet Toma-rw.dmg -format ULFO -o "$DMG"
rm -f Toma-rw.dmg
codesign --force $TIMESTAMP --sign "${IDENTITY:--}" "$DMG"

# Notarize and staple, so Gatekeeper opens the DMG without «Abrir igualmente». Needs a Developer ID
# signature and a notarytool keychain profile (create it once: xcrun notarytool store-credentials toma).
NOTARY_PROFILE=${NOTARY_PROFILE:-toma}
if [ "$TIMESTAMP" = "--timestamp" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "Notarizado y grapado: $DMG"
else
  echo "(sin notarizar: falta certificado Developer ID o perfil de notarytool \"$NOTARY_PROFILE\")"
fi
echo "Listo: $DMG"
