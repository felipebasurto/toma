#!/bin/sh
# Builds Toma.app from the Swift package. Usage: ./build.sh  →  ./Toma.app
set -eu
cd "$(dirname "$0")"
swift build -c release --arch arm64
APP=Toma.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/Toma "$APP/Contents/MacOS/Toma"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.toma</string>
  <key>CFBundleName</key><string>Toma</string>
  <key>CFBundleExecutable</key><string>Toma</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Toma graba la zona de la pantalla que eliges.</string>
  <key>NSMicrophoneUsageDescription</key><string>Toma graba tu voz junto a la pantalla cuando eliges «Sonido del Mac y micrófono».</string>
</dict></plist>
PLIST
# TCC keys the Screen Recording grant to the signature, so sign with a stable identity
# when there is one (rebuilds keep the permission); fall back to ad hoc.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
# Hardened runtime blocks the microphone unless the entitlement says otherwise.
ENTITLEMENTS=$(mktemp)
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
ENT
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "${IDENTITY:--}" --identifier app.toma "$APP"
rm -f "$ENTITLEMENTS"
echo "Listo: $APP"
