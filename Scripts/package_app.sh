#!/usr/bin/env bash
# Builds build/AILimit.app and signs it with a stable identity.
#
# Why the identity matters beyond "being signed": legacy Keychain items carry a
# per-application ACL keyed on the app's designated requirement. Ad-hoc signing
# derives that requirement from the code hash, so every rebuild produces a new
# identity and macOS re-prompts for access to items the app itself wrote --
# and a prompt that cannot be answered (asleep display, LSUIElement app) used to
# stall the refresh. A real certificate makes the requirement
# identifier-plus-certificate based, so it survives rebuilds.
#
# Identity selection, first match wins:
#   1. $AILIMIT_SIGN_IDENTITY  (explicit override)
#   2. Developer ID Application  (distributable, notarizable)
#   3. Apple Development         (stable, this machine only)
#   4. ad-hoc                    (last resort; warns, ACL churn returns)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_DIR="build/AILimit.app"

find_identity() {
    if [[ -n "${AILIMIT_SIGN_IDENTITY:-}" ]]; then
        printf '%s' "$AILIMIT_SIGN_IDENTITY"
        return
    fi
    local list
    list=$(security find-identity -v -p codesigning 2>/dev/null || true)
    for prefix in "Developer ID Application" "Apple Development"; do
        # `|| true`: a missing certificate makes grep exit non-zero, which
        # `set -e -o pipefail` would otherwise treat as fatal.
        local hash
        hash=$(printf '%s\n' "$list" | grep -F "$prefix" | head -1 | awk '{print $2}' || true)
        if [[ -n "$hash" ]]; then
            printf '%s' "$hash"
            return
        fi
    done
    printf '%s' "-"
}

IDENTITY=$(find_identity)
IDENTITY_NAME=$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$IDENTITY" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
[[ "$IDENTITY" == "-" ]] && IDENTITY_NAME="ad-hoc"

echo "==> Building (release)"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/AILimit" "$APP_DIR/Contents/MacOS/AILimit"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "==> Signing as: $IDENTITY_NAME"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
    # Hardened runtime is required for notarization and harmless otherwise.
    SIGN_ARGS+=(--options runtime)
    # A trusted timestamp keeps the signature valid past certificate expiry, but
    # needs the network; only Developer ID builds are actually distributed.
    if [[ "$IDENTITY_NAME" == "Developer ID Application"* ]]; then
        SIGN_ARGS+=(--timestamp)
    fi
fi
codesign "${SIGN_ARGS[@]}" "$APP_DIR"

echo "==> Verifying"
codesign --verify --strict --verbose=1 "$APP_DIR"
# Ad-hoc signatures print the requirement as a `# designated => cdhash ...`
# comment on stderr, so read both streams and allow the leading marker.
REQUIREMENT=$(codesign -d -r- "$APP_DIR" 2>&1 | sed -n 's/^#* *designated => //p')
echo "    designated requirement:"
echo "      $REQUIREMENT"

if [[ "$IDENTITY" == "-" ]]; then
    cat >&2 <<'WARN'

!!  Signed ad-hoc. The designated requirement is code-hash based, so every
!!  rebuild is a new identity to macOS and Keychain access must be re-approved
!!  (menubar refresh button, and Settings > "지금 가져오기 테스트").
!!  Install an Apple Development or Developer ID certificate to avoid this.
WARN
elif [[ "$REQUIREMENT" == *"cdhash"* ]]; then
    echo "!!  Requirement still pins a code hash; Keychain grants will not survive rebuilds." >&2
else
    echo "    stable across rebuilds (no code hash pinned)"
fi

echo "==> Created $APP_DIR"
echo "Install: rm -rf /Applications/AILimit.app && cp -R $APP_DIR /Applications/"
