#!/bin/bash
# Builds padmend.app.
#
# The bundle matters for more than tidiness: macOS grants Input Monitoring and
# Accessibility to a specific signed binary. A command-line build is attributed
# to whichever terminal launched it, so the permission has to be re-granted
# whenever that changes. A bundle with a stable identifier is its own subject
# and keeps its approval.
#
# The signature here is ad-hoc, which is enough for the permissions to stick on
# the machine that built it. Note that re-running this invalidates the old
# signature, so macOS may ask for the permissions again after an update.
set -euo pipefail

cd "$(dirname "$0")/.."
NAME="padmend"
BUNDLE="dist/${NAME}.app"
IDENTIFIER="com.sairammr.padmend"
VERSION="$(git describe --tags --always 2>/dev/null || echo dev)"

echo "building release binary"
swift build -c release --product "$NAME"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp ".build/release/${NAME}" "$BUNDLE/Contents/MacOS/${NAME}"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>padmend</string>
  <key>CFBundleDisplayName</key><string>padmend</string>
  <key>CFBundleIdentifier</key><string>${IDENTIFIER}</string>
  <key>CFBundleExecutable</key><string>${NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- No dock icon: this is a status item, not an application window. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null

echo
echo "built ${BUNDLE}"
echo
echo "Install it, then approve it in System Settings:"
echo "  cp -r ${BUNDLE} /Applications/"
echo "  open /Applications/${NAME}.app"
echo
echo "It needs Input Monitoring (to read the sensor) and Accessibility (to"
echo "replace what the sensor sends). It will ask for both on first launch."
