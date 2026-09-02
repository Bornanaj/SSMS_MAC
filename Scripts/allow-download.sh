#!/bin/bash
# Clears the quarantine flag from a downloaded SSMS for Mac installer, disk image or
# application bundle.
#
# What this actually does, so the decision is an informed one: macOS marks every file
# written by a sandboxed app — a browser, a chat client, AirDrop — with
# com.apple.quarantine, and Gatekeeper refuses to open anything carrying that mark
# unless Apple has notarized it. Removing the mark tells macOS you vouch for the file
# yourself. Only do that for a file you obtained from a source you trust.
#
#   ./Scripts/allow-download.sh ~/Downloads/SSMS-for-Mac-1.3.1.pkg
set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
    # Nothing given: offer whatever is sitting in Downloads.
    mapfile -t CANDIDATES < <(ls -t "$HOME"/Downloads/SSMS*for*Mac*.pkg \
                                    "$HOME"/Downloads/SSMS*forMac*.pkg \
                                    "$HOME"/Downloads/SSMS*for*Mac*.dmg \
                                    2>/dev/null | head -5)
    if [ "${#CANDIDATES[@]}" -eq 0 ]; then
        red "Pass the file to clear, for example:"
        echo "  ./Scripts/allow-download.sh ~/Downloads/SSMS-for-Mac-1.3.1.pkg"
        exit 1
    fi
    TARGET="${CANDIDATES[0]}"
    info "no path given, using the newest match: $TARGET"
fi

if [ ! -e "$TARGET" ]; then
    red "No such file: $TARGET"
    exit 1
fi

case "$TARGET" in
    *.pkg|*.dmg|*.app|*.app/) ;;
    *)
        red "Refusing: this only handles .pkg, .dmg and .app, and got $TARGET"
        exit 1
        ;;
esac

if ! xattr -p com.apple.quarantine "$TARGET" >/dev/null 2>&1; then
    green "$TARGET is not quarantined; it will open as it is."
    exit 0
fi

info "clearing com.apple.quarantine from $TARGET"
xattr -dr com.apple.quarantine "$TARGET"

if xattr -p com.apple.quarantine "$TARGET" >/dev/null 2>&1; then
    red "The attribute is still set. Try again with sudo."
    exit 1
fi

green "Done. Open it normally now:"
echo "  open \"$TARGET\""
