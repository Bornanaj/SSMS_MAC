# Gatekeeper, code signing and notarization

> **Short version:** the only way a *downloaded* macOS app opens with no warning is a
> Developer ID signature plus Apple notarization, which needs a paid Apple Developer
> Program membership. Building from source avoids the warning entirely, because a
> locally compiled app is never quarantined.

## Why the dialog appears

> "Apple could not verify *SSMS for Mac* is free of malware that may harm your Mac or
> compromise your privacy."

Two conditions have to both be true for macOS to show this:

1. **The file is quarantined.** Anything written by a sandboxed app — a browser, a chat
   client, AirDrop, Mail — gets the extended attribute `com.apple.quarantine`. Files you
   compile yourself, or copy with `cp`, `git clone` or `rsync`, do not.
2. **The app is not notarized.** Notarization is Apple scanning an uploaded build and
   issuing a ticket. Gatekeeper checks that ticket the first time a quarantined app runs.

Miss either condition and there is no prompt. That is the whole mechanism — there is no
build flag, `Info.plist` key, or entitlement that turns it off.

```
downloaded ──► quarantined ──► notarized?  ──yes──► opens silently
                                   │
                                   └──no───► "Apple could not verify..."

compiled locally ──► not quarantined ──────────────► opens silently
```

## The three ways to ship

| Path | Cost | Prompt on first launch |
|---|---|---|
| Build from source (`Scripts/install.sh`) | free | none |
| Unsigned `.pkg` installer | free | once, on the installer itself — not on the app |
| Unsigned `.dmg` download | free | yes, on the app, cleared by right-click → Open once |
| Developer ID + notarized | $99/year | none |

### Why the installer package behaves better

Quarantine is attached to the *downloaded file*. A `.dmg` is a container you copy the app
out of, and the copy inherits the flag, so the app itself is quarantined and Gatekeeper
challenges it. A `.pkg` is executed by Installer.app, which writes its payload directly;
the written bundle carries no quarantine attribute. One prompt on the installer replaces
a prompt on the app, and the app then launches normally forever after.

Signing an installer needs a **Developer ID Installer** certificate, which is a different
certificate from the Developer ID Application one used for the app. `Scripts/make-pkg.sh`
reads it from `DEVELOPER_ID_INSTALLER`, and the release workflow from the
`MACOS_DEVELOPER_ID_INSTALLER` secret.

### Build from source

This is what the README recommends and what `Scripts/install.sh` does. The app is
compiled on the machine that runs it, so no quarantine attribute is ever attached. Most
open-source macOS developer tools ship this way.

### Unsigned download

The app still runs; macOS just asks once. Either:

- right-click (or Control-click) the app → **Open** → **Open**, or
- `xattr -dr com.apple.quarantine "/Applications/SSMS for Mac.app"`

Telling users to strip quarantine is asking them to disable a security check, so it
belongs in a footnote, not in the headline install instructions.

### Developer ID and notarization

What it takes:

1. **Enrol** in the Apple Developer Program — <https://developer.apple.com/programs/>.
   $99/year, individual or organization. Approval usually takes a day or two.
2. **Create a Developer ID Application certificate** in Xcode
   (Settings → Accounts → Manage Certificates → + → Developer ID Application) or on the
   developer portal. Export it as a `.p12` with a password.
3. **Create an app-specific password** at <https://appleid.apple.com> → Sign-In and
   Security → App-Specific Passwords. This is not the Apple ID password.
4. **Find the team ID** — the ten character string in the certificate name, also shown in
   the developer portal under Membership.

Then locally:

```bash
export DEVELOPER_ID="Developer ID Application: Your Name (ABCDE12345)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="ABCDE12345"
export APPLE_APP_PASSWORD="abcd-efgh-ijkl-mnop"

./Scripts/build-app.sh release
./Scripts/sign-and-notarize.sh
```

The script signs the bundle with the hardened runtime (notarization refuses builds
without it), builds and signs the disk image, submits it to Apple, waits for the ticket,
staples it, and finally runs the same `spctl` assessment Gatekeeper performs. When the
last line prints, a downloaded copy opens with no prompt.

### In CI

`.github/workflows/release.yml` runs the same script on tag pushes. Add four repository
secrets under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | the `.p12`, base64 encoded: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | the password used when exporting the `.p12` |
| `MACOS_DEVELOPER_ID` | `Developer ID Application: Your Name (ABCDE12345)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | as above |

Until those exist the workflow still publishes a working unsigned disk image and says so
in the release notes, so nothing breaks in the meantime.

## Verifying a build

```bash
codesign -dv --verbose=4 "/Applications/SSMS for Mac.app"   # who signed it
xcrun stapler validate "SSMS-for-Mac-1.0.0.dmg"             # is the ticket attached
spctl --assess --type open --context context:primary-signature -v "SSMS-for-Mac-1.0.0.dmg"
xattr -p com.apple.quarantine "/Applications/SSMS for Mac.app"  # errors when not quarantined
```

`spctl` printing `accepted` with `source=Notarized Developer ID` is the state that
produces no dialog.

## What this project does not do

- **No self-signed certificate workaround.** Gatekeeper only trusts certificates chaining
  to Apple's root. A self-signed certificate changes nothing.
- **No installer package that disables Gatekeeper.** `spctl --master-disable` and
  friends weaken the whole system, and asking users to run them is not acceptable.
- **No stripping quarantine on the user's behalf during a download install.** The
  provided `install.sh` builds from source instead, which is legitimately safe.
