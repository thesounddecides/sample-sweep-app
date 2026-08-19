#!/bin/bash
# ---------------------------------------------------------------------------
# verify-release.sh — clean-room check of a shippable dmg. Non-zero on any miss.
# ---------------------------------------------------------------------------
# Every false pass while shipping Sample Sweep came from trusting an artifact
# on the build machine. This unpacks a COPY, sets the quarantine xattr the way
# Safari would, and asserts what a stranger's Mac will assert. Run it, don't
# eyeball it.
#   ./verify-release.sh build/__PASCAL__-1.0.0.dmg
# ---------------------------------------------------------------------------
set -uo pipefail
cd "$(dirname "$0")"
source ./config.sh

DMG="${1:?Usage: verify-release.sh <path.dmg>}"
[[ -f "$DMG" ]] || die "Not found: $DMG"

fails=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; fails=$((fails+1)); }
check() { # check <label> <command...>  → pass/fail on exit status
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

work="$(mktemp -d)"
mnt="$work/mnt"
trap 'hdiutil detach "$mnt" >/dev/null 2>&1; rm -rf "$work"' EXIT

step "Simulating a download"
cp "$DMG" "$work/dl.dmg"
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$work/dl.dmg"
pass "quarantine flag set on a copy"

step "The dmg itself"
check "signed (codesign --verify --strict)"      codesign --verify --strict "$work/dl.dmg"
check "notarization ticket stapled"              xcrun stapler validate "$work/dl.dmg"
# Capture, THEN match. Under pipefail, `cmd | grep -q` exits grep on the first
# hit, can SIGPIPE the still-writing cmd, and reports a false failure.
gk="$(spctl -a -vv -t open --context context:primary-signature "$work/dl.dmg" 2>&1 || true)"
case "$gk" in
    *"Notarized Developer ID"*) pass "Gatekeeper: Notarized Developer ID" ;;
    *) fail "Gatekeeper did NOT report Notarized Developer ID"; printf '%s\n' "$gk" | sed 's/^/      /' ;;
esac

step "Inside the dmg"
mkdir -p "$mnt"
hdiutil attach "$work/dl.dmg" -mountpoint "$mnt" -nobrowse -readonly >/dev/null 2>&1 \
    || die "could not mount $DMG"
APP_IN="$mnt/$APP_NAME.app"
[[ -d "$APP_IN" ]] && pass "contains $APP_NAME.app" || fail "no $APP_NAME.app inside"
[[ -L "$mnt/Applications" ]] && pass "Applications alias present" || fail "no Applications alias (not drag-to-install)"
[[ -f "$mnt/.DS_Store" ]] && pass "branded window layout stored (.DS_Store)" \
    || fail "no .DS_Store — window opens plain (Finder race in make-dmg? see SKILL.md)"

step "The app inside"
if [[ -d "$APP_IN" ]]; then
    check "signed (codesign --verify --strict)"  codesign --verify --strict "$APP_IN"
    check "notarization ticket stapled"          xcrun stapler validate "$APP_IN"
    gk="$(spctl -a -vv "$APP_IN" 2>&1 || true)"
    case "$gk" in
        *"Notarized Developer ID"*) pass "Gatekeeper: Notarized Developer ID" ;;
        *) fail "app not accepted by Gatekeeper" ;;
    esac
    cs="$(codesign -dvv "$APP_IN" 2>&1 || true)"
    case "$cs" in
        *"flags="*"(runtime)"*|*"flags="*"runtime"*) pass "hardened runtime" ;;
        *) fail "hardened runtime NOT set (notarization requires it)" ;;
    esac
    archs="$(lipo -archs "$APP_IN/Contents/MacOS/$APP_NAME" 2>/dev/null || true)"
    case "$archs" in
        *x86_64*arm64*|*arm64*x86_64*) pass "universal: $archs" ;;
        *) fail "NOT universal: '$archs' (Intel Macs excluded)" ;;
    esac
    v="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_IN/Contents/Info.plist" 2>/dev/null)"
    case "$(basename "$DMG")" in
        *"$v"*) pass "version $v matches dmg filename" ;;
        *) fail "app says $v but dmg is $(basename "$DMG")" ;;
    esac
fi

echo
if [[ $fails -eq 0 ]]; then
    printf '\033[32mREADY TO SHIP\033[0m  %s\n' "$DMG"
else
    printf '\033[31m%d CHECK(S) FAILED\033[0m — do not publish %s\n' "$fails" "$DMG"
    exit 1
fi
