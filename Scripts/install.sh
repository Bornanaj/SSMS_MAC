#!/bin/bash
# Builds SSMS for Mac from source and installs it into /Applications.
#
# Building locally is the only way to get an app that macOS opens without a
# Gatekeeper prompt unless the binary is signed with an Apple Developer ID and
# notarized: the quarantine flag is attached on download, never on compilation.
set -euo pipefail

REPO_URL="https://github.com/Bornanaj/SSMS_MAC.git"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP_NAME="SSMS for Mac.app"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }

# --- preflight ---------------------------------------------------------------

if [ "$(uname -s)" != "Darwin" ]; then
    red "SSMS for Mac only runs on macOS."
    exit 1
fi

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt 14 ]; then
    red "macOS 14 (Sonoma) or later is required; this machine reports $(sw_vers -productVersion)."
    exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
    red "The Xcode Command Line Tools are missing."
    echo "Install them with:  xcode-select --install"
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    red "No Swift toolchain found. Install the Command Line Tools:  xcode-select --install"
    exit 1
fi

SWIFT_MAJOR="$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -1)"
if [ -n "$SWIFT_MAJOR" ] && [ "$SWIFT_MAJOR" -lt 6 ]; then
    red "Swift 6 or later is required; found $(swift --version 2>&1 | head -1)"
    echo "Update the Command Line Tools from System Settings > General > Software Update."
    exit 1
fi

# --- source ------------------------------------------------------------------

if [ -f "$(dirname "${BASH_SOURCE[0]}")/../Package.swift" ]; then
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    info "building from the checkout at $ROOT"
else
    ROOT="$(mktemp -d)/SSMS_MAC"
    info "cloning $REPO_URL"
    git clone --depth 1 "$REPO_URL" "$ROOT" >/dev/null 2>&1
fi

cd "$ROOT"

# --- build -------------------------------------------------------------------

info "building (this takes a few minutes the first time)"
./Scripts/build-app.sh release

if [ ! -d "build/$APP_NAME" ]; then
    red "the build did not produce $APP_NAME"
    exit 1
fi

# --- install -----------------------------------------------------------------

TARGET="$INSTALL_DIR/$APP_NAME"
if [ -d "$TARGET" ]; then
    info "replacing the existing copy at $TARGET"
    rm -rf "$TARGET"
fi

info "installing to $TARGET"
if ! cp -R "build/$APP_NAME" "$TARGET" 2>/dev/null; then
    info "elevating to write to $INSTALL_DIR"
    sudo cp -R "build/$APP_NAME" "$TARGET"
    sudo chown -R "$(id -u):$(id -g)" "$TARGET"
fi

# A locally compiled app is never quarantined, but a stray flag can be inherited
# from the enclosing folder, so clear it and make sure the signature still checks.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
codesign --force --sign - --identifier dev.ssmsmac.app "$TARGET" >/dev/null 2>&1 || true

green "installed: $TARGET"
echo
echo "Open it from Launchpad, or run:  open \"$TARGET\""
