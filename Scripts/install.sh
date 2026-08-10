#!/usr/bin/env bash
# One command to go from a fresh clone to a running menu bar app.
#
#   ./Scripts/install.sh
#
# Everything here is automatable except two macOS dialogs, which no script (and
# no AI agent) can click on your behalf. Rather than failing on them obscurely,
# this checks for them up front and says exactly what to press at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
step() { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$1"; }
warn() { printf '%s!!%s  %s\n' "$YELLOW" "$OFF" "$1" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$OFF" "$1" >&2; exit 1; }

APP="/Applications/AILimit.app"

# --- Preflight ---------------------------------------------------------------
# Checked before building so a missing toolchain reports itself, instead of
# surfacing as an unreadable compiler error several steps later.

step "Checking prerequisites"

MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [[ "$MAJOR" -lt 14 ]]; then
    die "macOS 14 or newer is required (found $(sw_vers -productVersion))."
fi
printf '    macOS %s\n' "$(sw_vers -productVersion)"

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    cat >&2 <<EOF
${RED}error:${OFF} the Xcode command line tools are missing.

Install them, then run this script again:

    ${BOLD}xcode-select --install${OFF}

That opens a macOS installer dialog you have to click through — it cannot be
scripted. If you already have Xcode installed, this may fix it instead:

    ${BOLD}sudo xcode-select --switch /Applications/Xcode.app${OFF}
EOF
    exit 1
fi
printf '    %s\n' "$(swift --version 2>/dev/null | head -1)"

# --- Build -------------------------------------------------------------------

step "Building"
AILIMIT_SUPPRESS_INSTALL_HINT=1 ./Scripts/package_app.sh

# `package_app.sh` warns about ad-hoc signing itself; repeat the consequence
# here because it decides whether the Keychain step below recurs forever.
SIGNED_ADHOC=0
if codesign -d -r- build/AILimit.app 2>&1 | grep -q "cdhash"; then
    SIGNED_ADHOC=1
fi

# --- Install -----------------------------------------------------------------

step "Installing to /Applications"
if pgrep -f "$APP/Contents/MacOS/AILimit" >/dev/null 2>&1; then
    printf '    stopping the running copy\n'
    pkill -f "$APP/Contents/MacOS/AILimit" || true
    sleep 1
fi
rm -rf "$APP"
if ! cp -R build/AILimit.app "$APP" 2>/dev/null; then
    die "could not write to /Applications. Copy it manually:
    cp -R build/AILimit.app ~/Applications/"
fi
printf '    %s\n' "$APP"

step "Launching"
open "$APP"
sleep 3
pgrep -f "$APP/Contents/MacOS/AILimit" >/dev/null 2>&1 \
    || warn "the app does not appear to be running; check the menu bar."

# --- What only a human can do ------------------------------------------------

cat <<EOF

${GREEN}Done.${OFF} Look for the bar-chart icon in your menu bar.

${BOLD}Two steps left that need you to click${OFF} / ${BOLD}직접 눌러야 하는 두 단계${OFF}

  OpenAI and Cursor work immediately — they read plain local files.
  Claude and Qwen need macOS Keychain access, granted once, with the display awake:

    1. Click the menu bar icon, press the refresh button (↻)
       → choose ${BOLD}Always Allow${OFF} / ${BOLD}항상 허용${OFF}          (Claude)
    2. Open Settings, press "Import now" / "지금 가져오기 테스트"
       → choose ${BOLD}Always Allow${OFF} / ${BOLD}항상 허용${OFF}          (Qwen)

  These dialogs cannot be scripted. If the screen is asleep they never appear,
  so make sure the display is on.
EOF

if [[ "$SIGNED_ADHOC" == "1" ]]; then
    cat >&2 <<EOF

${YELLOW}Note:${OFF} this build is signed ad-hoc, so macOS treats every rebuild as a new
app and will ask for Keychain access again each time. Installing any Apple
Development certificate (free Apple ID accounts get one) makes the grant stick.
EOF
fi
