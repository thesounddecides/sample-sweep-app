#!/bin/bash
# ---------------------------------------------------------------------------
# notarize.sh — submit to Apple's notary service, then staple.
# ---------------------------------------------------------------------------
#   ./notarize.sh              → notarize + staple build/Sample Sweep.app
#   ./notarize.sh <path.dmg>   → notarize + staple that dmg
#
# An .app cannot be submitted directly (Apple takes an archive), so it is
# zipped for the upload and the TICKET IS STAPLED TO THE APP itself — that is
# what makes it pass Gatekeeper offline, however it later travels.
#
# Credentials come from config.sh (API key preferred, keychain profile as
# fallback) and are verified before anything is uploaded.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

TARGET="${1:-$APP}"
[[ -e "$TARGET" ]] || die "Not found: $TARGET"

step "Checking notary credentials"
assert_notary_credentials
ok "$NOTARY_AUTH_DESC"

case "$TARGET" in
    *.app)
        UPLOAD="build/notarize-upload.zip"
        step "Zipping the app for submission"
        rm -f "$UPLOAD"
        ditto -c -k --keepParent "$TARGET" "$UPLOAD"
        ok "$(du -h "$UPLOAD" | cut -f1)"
        ;;
    *) UPLOAD="$TARGET" ;;
esac

step "Submitting to Apple — can take a few minutes"
if ! xcrun notarytool submit "$UPLOAD" "${NOTARY_AUTH[@]}" --wait; then
    die "Notarization was not Accepted. Pull the reasons with:
    xcrun notarytool log <submission-id> ${NOTARY_AUTH[*]}
  (the submission-id is printed above)."
fi
ok "Accepted by Apple"

step "Stapling the ticket"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET" >/dev/null
ok "stapled to $TARGET"

step "Verifying as Gatekeeper will see it"
case "$TARGET" in
    *.dmg) spctl -a -vvv -t open --context context:primary-signature "$TARGET" 2>&1 | tail -3 ;;
    *)     spctl -a -vv "$TARGET" 2>&1 | tail -3 ;;
esac
[[ "${UPLOAD:-}" == "build/notarize-upload.zip" ]] && rm -f "$UPLOAD"
ok "notarized + stapled: $TARGET"
