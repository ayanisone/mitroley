#!/bin/zsh
# Builds mitroley.app into ./build. Needs only the Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/mitroley.app
rm -rf "$APP" build/Foley.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Foley .build/release/foley-mcp "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [ ! -f Support/AppIcon.icns ]; then
  TMP=$(mktemp -d)
  swiftc -O Support/make-icon.swift -o "$TMP/make-icon" && "$TMP/make-icon" "$TMP/icon.png"
  mkdir "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o Support/AppIcon.icns
  rm -rf "$TMP"
fi
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP/Contents/MacOS/foley-mcp" 2>/dev/null
codesign --force --sign - "$APP" 2>/dev/null
echo "Built $APP"
