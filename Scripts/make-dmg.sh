#!/bin/bash
# Builds SSMS for Mac and packages it as a compressed disk image.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$ROOT/build/SSMS for Mac.app/Contents/Info.plist" 2>/dev/null || echo 1.0.0)"
VOLUME="SSMS for Mac"
STAGING="$ROOT/build/dmg-staging"
DMG="$ROOT/build/SSMS-for-Mac-$VERSION.dmg"

cd "$ROOT"
# "release-skip-build" reuses the bundle already in build/, which is how the
# signing pipeline avoids clobbering a Developer ID signature with a fresh
# ad-hoc one.
if [ "$CONFIG" = "release-skip-build" ]; then
    [ -d "$ROOT/build/SSMS for Mac.app" ] || {
        echo "no app bundle to package; run Scripts/build-app.sh first"; exit 1; }
else
    "$ROOT/Scripts/build-app.sh" "$CONFIG"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$ROOT/build/SSMS for Mac.app/Contents/Info.plist")"
DMG="$ROOT/build/SSMS-for-Mac-$VERSION.dmg"

echo "==> staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$ROOT/build/SSMS for Mac.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# The app is signed ad hoc, so first launch needs the right-click gesture.
cat > "$STAGING/Read Me First.txt" <<'NOTE'
SSMS for Mac
============

Install
-------
Drag "SSMS for Mac" onto the Applications folder in this window.

First launch
------------
This build is signed ad hoc rather than with an Apple Developer ID, so macOS will
refuse the first double click. Open it once this way instead:

    right-click (or Control-click) the app in Applications -> Open -> Open

macOS remembers the choice; every launch after that is a normal double click.

If macOS says the app "is damaged and can't be opened", the quarantine flag was
applied while the file was being moved around. Clear it with:

    xattr -dr com.apple.quarantine "/Applications/SSMS for Mac.app"

Connecting
----------
File -> Connect to Server, or the + button above the Object Explorer.
Server name accepts host, host,port, host\INSTANCE and tcp:host,port.
"Trust server certificate" is on by default, which is what a local or
development server with a self-signed certificate needs.

Nothing else has to be installed: the SQL Server protocol is implemented inside
the app, so there is no ODBC driver, FreeTDS or JVM to set up.
NOTE

# Give the volume the app's icon. Finder needs the custom-icon bit set in FinderInfo,
# which SetFile would normally do; SetFile ships with Xcode, so set the bit directly.
cp "$ROOT/build/AppIcon.icns" "$STAGING/.VolumeIcon.icns"

RW_DMG="$ROOT/build/rw.dmg"
rm -f "$RW_DMG"

echo "==> creating the image"
hdiutil create \
    -volname "$VOLUME" \
    -srcfolder "$STAGING" \
    -ov -format UDRW \
    "$RW_DMG" >/dev/null

# Finder only shows .VolumeIcon.icns when the volume carries the custom-icon flag.
# SetFile would set it, but that ships with Xcode, so write the FinderInfo bit directly.
MOUNT_POINT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" |
    grep -E '/Volumes/' | tail -1 | sed -E 's/.*(\/Volumes\/.*)$/\1/')"
if [ -n "$MOUNT_POINT" ]; then
    # 32 byte FinderInfo record; bytes 8-9 are the Finder flags and 0x0400 is
    # kHasCustomIcon, which is what makes Finder pick up .VolumeIcon.icns.
    xattr -wx com.apple.FinderInfo \
        "0000000000000000040000000000000000000000000000000000000000000000" \
        "$MOUNT_POINT" 2>/dev/null || true
    sync
    hdiutil detach "$MOUNT_POINT" >/dev/null
fi

echo "==> compressing"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGING"

SIZE="$(du -h "$DMG" | cut -f1)"
echo "==> built: $DMG ($SIZE)"
