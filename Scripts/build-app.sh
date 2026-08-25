#!/bin/bash
# Builds SSMS for Mac and assembles a runnable .app bundle.
# Xcode is not required: SwiftPM produces the binary and we wrap it by hand.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/SSMS for Mac.app"
VERSION="1.0.2"

cd "$ROOT"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/ssms-mac"
[ -x "$BIN" ] || { echo "binary not found at $BIN"; exit 1; }

# The icon is generated rather than checked in, so it stays in step with the script.
if [ ! -f "$ROOT/build/AppIcon.icns" ]; then
    echo "==> generating the app icon"
    mkdir -p "$ROOT/build"
    swift "$ROOT/Scripts/make-icon.swift" "$ROOT/build/AppIcon.iconset" >/dev/null
    iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SSMS for Mac"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SSMS for Mac</string>
    <key>CFBundleIdentifier</key><string>dev.ssmsmac.app</string>
    <key>CFBundleName</key><string>SSMS for Mac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDisplayName</key><string>SSMS for Mac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSHumanReadableCopyright</key><string>Built with TDSKit</string>
    <key>CFBundleDocumentTypes</key>
    <array>
      <dict>
        <key>CFBundleTypeName</key><string>SQL Script</string>
        <key>CFBundleTypeRole</key><string>Editor</string>
        <key>LSItemContentTypes</key><array><string>public.plain-text</string></array>
      </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper and the keychain both accept the bundle.
codesign --force --sign - --identifier dev.ssmsmac.app "$APP" >/dev/null 2>&1 || true

echo "==> built: $APP"
