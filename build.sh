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

# TCC keys the Screen Recording grant to the signature, so sign with a stable identity
# when there is one (rebuilds keep the permission); fall back to ad hoc.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')
# Hardened runtime blocks the microphone unless the entitlement says otherwise.
ENTITLEMENTS=$(mktemp)
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
ENT
codesign --force --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" --sign "${IDENTITY:--}" --identifier app.toma "$APP"
rm -f "$ENTITLEMENTS"
echo "Listo: $APP ($VERSION)"

[ "${1:-}" = "dmg" ] || exit 0

# Disk image: Toma.app next to an Applications shortcut, laid out by Finder.
DMG=Toma.dmg
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Aplicaciones"
rm -f "$DMG" Toma-rw.dmg
hdiutil create -quiet -volname Toma -srcfolder "$STAGE" -fs HFS+ -format UDRW -size 20m Toma-rw.dmg
rm -rf "$STAGE"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen Toma-rw.dmg | awk '/Apple_HFS/ {print $1}')
cp Resources/Toma.icns /Volumes/Toma/.VolumeIcon.icns
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
codesign --force --timestamp=none --sign "${IDENTITY:--}" "$DMG"
echo "Listo: $DMG"
