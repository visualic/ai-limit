#!/usr/bin/env bash
# Builds a DMG that opens on someone else's Mac without Gatekeeper blocking it.
#
# Ad-hoc or Apple Development signatures are fine on the machine that built them,
# but macOS refuses to launch them elsewhere. Distribution needs three things,
# and all three must be present or Gatekeeper still complains:
#   1. a Developer ID Application signature
#   2. the hardened runtime (already enabled by package_app.sh)
#   3. a notarization ticket, stapled so it works offline
#
# Usage:
#   Scripts/release.sh                 # full release (requires cert + credentials)
#   Scripts/release.sh --skip-notarize # build/sign/package only, for a dry run
#
# One-time setup:
#   1. Create the certificate (Account Holder only):
#        Xcode > Settings > Accounts > <team> > Manage Certificates > + >
#        Developer ID Application
#      If that entry is missing, you are not the Account Holder for that team —
#      use a team where you are, or create it on developer.apple.com.
#   2. Store notarization credentials once:
#        xcrun notarytool store-credentials AILimit \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#      App-specific passwords come from appleid.apple.com > Sign-In and Security.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${AILIMIT_NOTARY_PROFILE:-AILimit}"
SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

APP="build/AILimit.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/AILimit-${VERSION}.dmg"
STAGING="build/dmg-staging"

fail() { echo "error: $*" >&2; exit 1; }

# --- 1. Certificate -----------------------------------------------------------
# `|| true`: grep exits non-zero when there is no certificate, and with
# `set -e -o pipefail` that would abort the script before the helpful message
# below ever prints.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "Developer ID Application" | head -1 | awk '{print $2}' || true)
if [[ -z "$IDENTITY" ]]; then
    cat >&2 <<'MSG'
error: no "Developer ID Application" certificate found.

Apps signed with Apple Development run only on this Mac. To ship to others,
create the Developer ID certificate first:

  Xcode > Settings > Accounts > <team> > Manage Certificates > + >
  Developer ID Application

If that option is not in the + menu, the signed-in account is not the Account
Holder for that team. Switch to a team where it is (a personal team usually
qualifies), or have the Account Holder create it at developer.apple.com.
MSG
    exit 1
fi
IDENTITY_NAME=$(security find-identity -v -p codesigning | grep -F "$IDENTITY" | sed 's/.*"\(.*\)"/\1/' || true)
TEAM_ID=$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$IDENTITY_NAME" || true)
echo "==> Developer ID: $IDENTITY_NAME"

# --- 2. Build and sign the app ------------------------------------------------
AILIMIT_SIGN_IDENTITY="$IDENTITY" ./Scripts/package_app.sh

# Gatekeeper rejects a Developer ID app that is missing the hardened runtime,
# and notarization rejects it outright, so fail here rather than after upload.
#
# Captured to a variable rather than piped into `grep -q`: that closes the pipe
# on first match, `codesign` dies of SIGPIPE, and `pipefail` reports the whole
# pipeline as failed even though the flag was present.
CODESIGN_INFO=$(codesign -dv "$APP" 2>&1 || true)
case "$CODESIGN_INFO" in
    *"flags="*runtime*) ;;
    *) fail "hardened runtime missing; notarization would be rejected" ;;
esac

# --- 3. Package ---------------------------------------------------------------
echo "==> Building $DMG"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "AILimit" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"

# Signing the DMG means the download itself is verifiable, not just the app.
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    echo "==> Skipped notarization (--skip-notarize)."
    echo "    $DMG will still be blocked on other Macs until it is notarized."
    exit 0
fi

# --- 4. Notarize --------------------------------------------------------------
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    fail "no notarytool profile '$NOTARY_PROFILE'. Run:
  xcrun notarytool store-credentials $NOTARY_PROFILE \\
    --apple-id <your-apple-id> --team-id ${TEAM_ID:-<TEAMID>} --password <app-specific-password>"
fi

echo "==> Notarizing (usually a few minutes)"
if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
    echo "--- notarization log ---" >&2
    SUBMISSION=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>/dev/null \
        | awk '/id:/ {print $2; exit}')
    [[ -n "$SUBMISSION" ]] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" >&2
    fail "notarization failed"
fi

# --- 5. Staple ----------------------------------------------------------------
# Stapling attaches the ticket so the app opens even without a network round trip.
echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# --- 6. Verify the way Gatekeeper will ---------------------------------------
echo "==> Verifying"
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /'
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "==> $DMG is ready to distribute."
echo "    Recipients drag AILimit to Applications; no Gatekeeper warning."
