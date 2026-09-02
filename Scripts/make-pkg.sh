#!/bin/bash
# Builds SSMS for Mac and wraps it in a macOS installer package: the Continue /
# Continue / Install wizard, rather than the drag-to-Applications disk image.
#
# Installing this way also sidesteps Gatekeeper on the app itself. The quarantine flag
# lands on the downloaded .pkg, not on the payload it writes, so the installed app
# opens with no prompt.
#
# Set DEVELOPER_ID_INSTALLER to a "Developer ID Installer" certificate to sign the
# package; without it the build still works, it is just unsigned.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTIFIER="dev.ssmsmac.app"
APP_NAME="SSMS for Mac.app"

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }

cd "$ROOT"

if [ "$CONFIG" = "skip-build" ]; then
    [ -d "build/$APP_NAME" ] || { echo "no app bundle; run Scripts/build-app.sh first"; exit 1; }
else
    "$ROOT/Scripts/build-app.sh" "$CONFIG"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "build/$APP_NAME/Contents/Info.plist")"
STAGING="$ROOT/build/pkg-root"
SCRIPTS="$ROOT/build/pkg-scripts"
COMPONENT="$ROOT/build/component.pkg"
PKG="$ROOT/build/SSMS-for-Mac-$VERSION.pkg"

info "staging $VERSION"
rm -rf "$STAGING" "$SCRIPTS" "$COMPONENT" "$PKG"
mkdir -p "$STAGING/Applications" "$SCRIPTS"
cp -R "build/$APP_NAME" "$STAGING/Applications/"

# The installer runs as root, so anything it writes would otherwise be root-owned and
# unwritable by the user later.
cat > "$SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -e
APP="/Applications/SSMS for Mac.app"
# Installed payloads are not quarantined, but a previous drag-install might have left
# the flag behind on a bundle this run replaced.
/usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
# Hand the bundle to the console user rather than leaving it owned by root.
CONSOLE_USER="$(/usr/bin/stat -f "%Su" /dev/console 2>/dev/null || echo root)"
if [ "$CONSOLE_USER" != "root" ] && [ -n "$CONSOLE_USER" ]; then
    /usr/sbin/chown -R "$CONSOLE_USER" "$APP" 2>/dev/null || true
fi
exit 0
POSTINSTALL
chmod +x "$SCRIPTS/postinstall"

info "regenerating the installer artwork"
swift "$ROOT/Scripts/make-installer-art.swift" \
    "$ROOT/Scripts/Installer/Resources/background.png" \
    "$ROOT/build/AppIcon.icns" >/dev/null

info "building the component package"
pkgbuild \
    --root "$STAGING" \
    --scripts "$SCRIPTS" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location / \
    "$COMPONENT" >/dev/null

info "writing the distribution"
DISTRIBUTION="$ROOT/build/distribution.xml"
cat > "$DISTRIBUTION" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>SSMS for Mac</title>
    <organization>dev.ssmsmac</organization>
    <background file="background.png" mime-type="image/png"
                alignment="bottomleft" scaling="proportional"/>
    <background-darkAqua file="background.png" mime-type="image/png"
                         alignment="bottomleft" scaling="proportional"/>
    <welcome file="welcome.html" mime-type="text/html"/>
    <readme file="readme.html" mime-type="text/html"/>
    <license file="license.txt" mime-type="text/plain"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="allow" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="14.0"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="$IDENTIFIER"/>
    </choices-outline>
    <choice id="$IDENTIFIER" title="SSMS for Mac"
            description="The application, installed into /Applications.">
        <pkg-ref id="$IDENTIFIER"/>
    </choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML

info "building the installer"
productbuild \
    --distribution "$DISTRIBUTION" \
    --resources "$ROOT/Scripts/Installer/Resources" \
    --package-path "$ROOT/build" \
    "$PKG" >/dev/null

if [ -n "${DEVELOPER_ID_INSTALLER:-}" ]; then
    info "signing with $DEVELOPER_ID_INSTALLER"
    productsign --sign "$DEVELOPER_ID_INSTALLER" "$PKG" "$PKG.signed"
    mv "$PKG.signed" "$PKG"
    pkgutil --check-signature "$PKG" | head -3
else
    warn "DEVELOPER_ID_INSTALLER is not set - the installer is unsigned."
    warn "macOS will ask before opening a downloaded copy; see docs/CODE_SIGNING.md."
fi

rm -rf "$STAGING" "$SCRIPTS" "$COMPONENT" "$DISTRIBUTION"

SIZE="$(du -h "$PKG" | cut -f1)"
info "built: $PKG ($SIZE)"
