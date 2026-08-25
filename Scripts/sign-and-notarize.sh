#!/bin/bash
# Signs the app with a Developer ID, notarizes it with Apple, and staples the
# ticket to both the app and the disk image.
#
# This is what removes the "Apple could not verify..." dialog for a DOWNLOADED
# build. Nothing else does: Gatekeeper only trusts a notarized signature, and
# notarization requires a paid Apple Developer Program membership.
#
# Required environment:
#   DEVELOPER_ID       "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID           the Apple account email
#   APPLE_TEAM_ID      the 10 character team identifier
#   APPLE_APP_PASSWORD an app-specific password from appleid.apple.com
#
# When DEVELOPER_ID is unset the script exits 0 without doing anything, so the
# release pipeline still produces an unsigned build for people who build locally.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/SSMS for Mac.app"
ENTITLEMENTS="$ROOT/Scripts/entitlements.plist"

info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }

[ -d "$APP" ] || { echo "no app at $APP — run Scripts/build-app.sh first"; exit 1; }

if [ -n "${DEVELOPER_ID:-}" ]; then
    info "signing with $DEVELOPER_ID"
    # --options runtime enables the hardened runtime, which notarization requires.
    codesign --force --deep --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$DEVELOPER_ID" \
        "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    warn "DEVELOPER_ID is not set — keeping the ad-hoc signature."
    warn "Downloaded copies of this build will show the Gatekeeper prompt."
    warn "See docs/CODE_SIGNING.md for what to configure."
fi

info "building the disk image"
"$ROOT/Scripts/make-dmg.sh" release-skip-build

DMG="$(ls -t "$ROOT"/build/SSMS-for-Mac-*.dmg | head -1)"
[ -n "$DMG" ] || { echo "no disk image was produced"; exit 1; }

if [ -z "${DEVELOPER_ID:-}" ]; then
    info "unsigned disk image ready: $DMG"
    exit 0
fi

info "signing $DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${APPLE_APP_PASSWORD:-}" ]; then
    warn "notarization credentials are missing — the build is signed but not notarized."
    warn "Gatekeeper will still prompt on downloaded copies."
    exit 0
fi

info "submitting to Apple for notarization (this usually takes a few minutes)"
xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

info "stapling the ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

info "verifying the way Gatekeeper will see it"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

printf '\033[32m%s\033[0m\n' "notarized: $DMG"
